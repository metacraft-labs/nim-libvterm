## decoders/png.nim -- minimal PNG decoder for Kitty f=100 and iTerm2
## PNG-format inline images.
##
## Scope: enough of the PNG spec (RFC 2083 / W3C PNG 2nd ed.) to round-
## trip the screen-capture-style PNGs that Kitty and iTerm2 actually send.
##
## Supported
## ---------
##  * Color types:
##      - 2 (truecolor RGB, 8-bit)        => expanded to RGBA, alpha=255
##      - 6 (truecolor + alpha RGBA, 8-bit) => copied
##      - 3 (palette indexed, 8-bit)      => expanded via PLTE; alpha=255
##  * All five PNG filter types: None, Sub, Up, Average, Paeth.
##  * Multiple IDAT chunks (concatenated before zlib inflate; the spec
##    requires this).
##  * CRC32 verification on every chunk.
##
## Deferred (raises =PngDecodeError= with an explicit message)
## ------------------------------------------------------------
##  * Adam7 interlacing -- uncommon in screen-capture / TUI PNGs.
##  * 16-bit-per-channel depth -- screenshots are essentially never 16bpc.
##  * Color types 0 (greyscale) and 4 (greyscale + alpha) -- terminal
##    image protocols overwhelmingly carry RGB(A).
##  * tRNS, gAMA, iCCP, sRGB, tEXt and other ancillary chunks -- silently
##    ignored (CRC is still verified, the chunk just isn't acted on).
##
## Public-API rules: returns a value =Image=. No `ref`. No `cast` in the
## public API. Errors are =PngDecodeError= -- a single exception type so
## callers can wrap with one =except=.

import ../image_types
import ../zlib_ffi
export image_types

type
  PngDecodeError* = object of CatchableError

const PngSignature: array[8, byte] = [
  0x89'u8, 0x50'u8, 0x4E'u8, 0x47'u8,
  0x0D'u8, 0x0A'u8, 0x1A'u8, 0x0A'u8
]

# ---------------------------------------------------------------------------
# Big-endian integer helpers (PNG is network-byte-order).
# ---------------------------------------------------------------------------

proc be32(buf: openArray[byte]; off: int): uint32 =
  if off + 4 > buf.len:
    raise newException(PngDecodeError,
      "png: truncated u32 at offset " & $off)
  (uint32(buf[off]) shl 24) or
  (uint32(buf[off + 1]) shl 16) or
  (uint32(buf[off + 2]) shl 8) or
  uint32(buf[off + 3])

# ---------------------------------------------------------------------------
# Filter algorithms (PNG 1.2 §9.2)
# ---------------------------------------------------------------------------
#
# `bpp` here is the "filter unit" -- bytes per pixel in the FILTERED
# stream. For color type 2 it's 3, for type 6 it's 4, for type 3 it's 1.
# Filters operate per byte: prev = same-byte-of-previous-pixel-this-row,
# up = same-byte-of-this-pixel-previous-row, upleft = same-byte-of-
# previous-pixel-previous-row.

proc paethPredictor(a, b, c: int): int =
  let p = a + b - c
  let pa = abs(p - a)
  let pb = abs(p - b)
  let pc = abs(p - c)
  if pa <= pb and pa <= pc: a
  elif pb <= pc: b
  else: c

proc unfilterScanline(filterType: byte; row: var openArray[byte];
                      prev: openArray[byte]; bpp: int) =
  ## Reverse one PNG filter in place. `row` is the unfiltered buffer
  ## (filter byte already stripped). `prev` is the previously-decoded
  ## scanline (same length as `row`); for the first row callers pass an
  ## all-zero buffer, per the spec.
  let n = row.len
  case filterType
  of 0:
    discard  # None
  of 1:
    # Sub: each byte reads its same-byte-of-previous-pixel.
    var i = bpp
    while i < n:
      row[i] = byte((int(row[i]) + int(row[i - bpp])) and 0xFF)
      inc i
  of 2:
    # Up: add the previous scanline byte-for-byte.
    var i = 0
    while i < n:
      row[i] = byte((int(row[i]) + int(prev[i])) and 0xFF)
      inc i
  of 3:
    # Average: floor((left + above) / 2).
    var i = 0
    while i < n:
      let left = if i < bpp: 0 else: int(row[i - bpp])
      let above = int(prev[i])
      row[i] = byte((int(row[i]) + (left + above) div 2) and 0xFF)
      inc i
  of 4:
    # Paeth.
    var i = 0
    while i < n:
      let left = if i < bpp: 0 else: int(row[i - bpp])
      let above = int(prev[i])
      let upperLeft = if i < bpp: 0 else: int(prev[i - bpp])
      let pred = paethPredictor(left, above, upperLeft)
      row[i] = byte((int(row[i]) + pred) and 0xFF)
      inc i
  else:
    raise newException(PngDecodeError,
      "png: unknown filter type " & $filterType)

# ---------------------------------------------------------------------------
# Public entry point
# ---------------------------------------------------------------------------

proc decodePng*(payload: openArray[byte]): Image =
  ## Decode a PNG byte buffer to an RGBA Image.
  ##
  ## Raises =PngDecodeError= on:
  ##   * Bad signature.
  ##   * Missing/duplicate IHDR or IEND.
  ##   * CRC32 mismatch on any chunk.
  ##   * Unsupported color type / bit depth / interlace method.
  ##   * Filter type out of [0..4].
  ##   * Truncated zlib stream.

  if payload.len < 8 + 12 + 12:  # signature + IHDR header skeleton + IEND
    raise newException(PngDecodeError,
      "png: payload too small (" & $payload.len & " bytes)")

  for i in 0 .. 7:
    if payload[i] != PngSignature[i]:
      raise newException(PngDecodeError,
        "png: bad signature at byte " & $i)

  # Walk chunks: 4-byte length, 4-byte type, length-byte payload,
  # 4-byte CRC32 (over type ++ payload). Spec is strict about IHDR
  # being first and IEND being last.
  var off = 8
  var sawIHDR = false
  var sawIEND = false
  var width = 0
  var height = 0
  var bitDepth = 0
  var colorType = 0
  var interlace = 0
  var palette: seq[byte] = @[]   # PLTE: 3 bytes/entry, max 256 entries
  var idatRaw: seq[byte] = @[]

  while off < payload.len:
    if off + 8 > payload.len:
      raise newException(PngDecodeError,
        "png: chunk header truncated at offset " & $off)
    let length = int(be32(payload, off))
    let typeOff = off + 4
    let dataOff = off + 8
    let crcOff = dataOff + length
    if crcOff + 4 > payload.len:
      raise newException(PngDecodeError,
        "png: chunk body truncated at offset " & $off)

    # Compute CRC over (type ++ data) and verify.
    let crcCalc = crc32Update(0'u32, payload.toOpenArray(typeOff, typeOff + 3))
    let crcFull = if length > 0:
      crc32Update(crcCalc, payload.toOpenArray(dataOff, dataOff + length - 1))
    else:
      crcCalc
    let crcStored = be32(payload, crcOff)
    if crcStored != crcFull:
      raise newException(PngDecodeError,
        "png: CRC32 mismatch in chunk at offset " & $off &
        " (stored=" & $crcStored & ", computed=" & $crcFull & ")")

    let chunkType = (chr(payload[typeOff]), chr(payload[typeOff + 1]),
                     chr(payload[typeOff + 2]), chr(payload[typeOff + 3]))

    if chunkType == ('I', 'H', 'D', 'R'):
      if sawIHDR:
        raise newException(PngDecodeError, "png: duplicate IHDR")
      if length != 13:
        raise newException(PngDecodeError,
          "png: IHDR length " & $length & " (must be 13)")
      width = int(be32(payload, dataOff))
      height = int(be32(payload, dataOff + 4))
      bitDepth = int(payload[dataOff + 8])
      colorType = int(payload[dataOff + 9])
      let compression = int(payload[dataOff + 10])
      let filterMethod = int(payload[dataOff + 11])
      interlace = int(payload[dataOff + 12])
      if width <= 0 or height <= 0:
        raise newException(PngDecodeError,
          "png: invalid dimensions " & $width & "x" & $height)
      if compression != 0:
        raise newException(PngDecodeError,
          "png: unsupported compression method " & $compression)
      if filterMethod != 0:
        raise newException(PngDecodeError,
          "png: unsupported filter method " & $filterMethod)
      if interlace == 1:
        raise newException(PngDecodeError,
          "png: interlaced PNGs not supported (Adam7 deferred)")
      if interlace != 0:
        raise newException(PngDecodeError,
          "png: unknown interlace method " & $interlace)
      if bitDepth == 16:
        raise newException(PngDecodeError,
          "png: 16-bit-per-channel PNGs not supported")
      if bitDepth != 8:
        raise newException(PngDecodeError,
          "png: only 8-bit depth supported (got " & $bitDepth & ")")
      case colorType
      of 2, 6, 3:
        discard  # supported
      of 0, 4:
        raise newException(PngDecodeError,
          "png: greyscale color types (0, 4) not supported")
      else:
        raise newException(PngDecodeError,
          "png: unknown color type " & $colorType)
      sawIHDR = true

    elif chunkType == ('P', 'L', 'T', 'E'):
      if not sawIHDR:
        raise newException(PngDecodeError, "png: PLTE before IHDR")
      if length mod 3 != 0:
        raise newException(PngDecodeError,
          "png: PLTE length not a multiple of 3 (" & $length & ")")
      if length > 256 * 3:
        raise newException(PngDecodeError,
          "png: PLTE has more than 256 entries")
      palette = newSeq[byte](length)
      for k in 0 ..< length:
        palette[k] = payload[dataOff + k]

    elif chunkType == ('I', 'D', 'A', 'T'):
      if not sawIHDR:
        raise newException(PngDecodeError, "png: IDAT before IHDR")
      let oldLen = idatRaw.len
      idatRaw.setLen(oldLen + length)
      for k in 0 ..< length:
        idatRaw[oldLen + k] = payload[dataOff + k]

    elif chunkType == ('I', 'E', 'N', 'D'):
      sawIEND = true
      off = crcOff + 4
      break

    else:
      # Ancillary chunk -- CRC verified above, otherwise ignored.
      discard

    off = crcOff + 4

  if not sawIHDR:
    raise newException(PngDecodeError, "png: missing IHDR")
  if not sawIEND:
    raise newException(PngDecodeError, "png: missing IEND")
  if idatRaw.len == 0:
    raise newException(PngDecodeError, "png: no IDAT data")
  if colorType == 3 and palette.len == 0:
    raise newException(PngDecodeError,
      "png: indexed-color (type 3) requires PLTE chunk")

  # Inflate the concatenated IDAT stream.
  var inflated: seq[byte]
  try:
    inflated = inflateBytes(idatRaw)
  except ZlibError as e:
    raise newException(PngDecodeError, "png: zlib inflate failed: " & e.msg)

  # Bytes-per-pixel in the FILTERED stream:
  #   type 2 (RGB)   -> 3
  #   type 6 (RGBA)  -> 4
  #   type 3 (index) -> 1
  let filterBpp = case colorType
                  of 2: 3
                  of 6: 4
                  of 3: 1
                  else: 0  # unreachable; vetted above
  let scanlineBytes = width * filterBpp
  let expected = (1 + scanlineBytes) * height
  if inflated.len < expected:
    raise newException(PngDecodeError,
      "png: inflated data too short (" & $inflated.len &
      " bytes, expected " & $expected & ")")

  # Unfilter row-by-row, emit RGBA on the fly.
  result.format = ifPlaceholder  # replaced by caller (Kitty/iTerm2)
  result.width = width
  result.height = height
  result.rawSize = payload.len
  result.pixels = newSeq[byte](width * height * 4)

  var prev = newSeq[byte](scanlineBytes)  # all zeros for row 0
  var cur = newSeq[byte](scanlineBytes)
  var srcOff = 0
  for y in 0 ..< height:
    let filterType = inflated[srcOff]
    inc srcOff
    for k in 0 ..< scanlineBytes:
      cur[k] = inflated[srcOff + k]
    srcOff += scanlineBytes
    unfilterScanline(filterType, cur, prev, filterBpp)

    let dstRow = y * width * 4
    case colorType
    of 6:
      # RGBA -> RGBA, byte-for-byte.
      for x in 0 ..< width:
        let s = x * 4
        let d = dstRow + x * 4
        result.pixels[d + 0] = cur[s + 0]
        result.pixels[d + 1] = cur[s + 1]
        result.pixels[d + 2] = cur[s + 2]
        result.pixels[d + 3] = cur[s + 3]
    of 2:
      # RGB -> RGBA with alpha=255.
      for x in 0 ..< width:
        let s = x * 3
        let d = dstRow + x * 4
        result.pixels[d + 0] = cur[s + 0]
        result.pixels[d + 1] = cur[s + 1]
        result.pixels[d + 2] = cur[s + 2]
        result.pixels[d + 3] = 0xFF
    of 3:
      # Indexed -> RGBA via PLTE; alpha=255 (no tRNS support).
      for x in 0 ..< width:
        let idx = int(cur[x])
        let pOff = idx * 3
        if pOff + 2 >= palette.len:
          raise newException(PngDecodeError,
            "png: palette index " & $idx & " out of range")
        let d = dstRow + x * 4
        result.pixels[d + 0] = palette[pOff + 0]
        result.pixels[d + 1] = palette[pOff + 1]
        result.pixels[d + 2] = palette[pOff + 2]
        result.pixels[d + 3] = 0xFF
    else:
      discard  # unreachable

    swap(prev, cur)
