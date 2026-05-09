## decoders/iterm2.nim -- iTerm2 OSC 1337 inline-image decoder.
##
## Format (post-OSC-1337-and-`File=`-prefix):
##
##   File=<key>=<value>;<key>=<value>;...:<base64-image-bytes>
##
## The trailing payload is base64-encoded bytes of an image. The iTerm2
## protocol deliberately does not restrict the inner format -- "PNG, GIF,
## JPEG, or other format". We decode BMP and PNG inline; JPEG and GIF
## still raise `IItermDecodeDefer`.
##
## Inner-format detection is by magic bytes:
##   * `BM`  (0x42 0x4D)         -> 24-bit uncompressed BMP (decoded)
##   * `\x89PNG`                  -> PNG decoder (decoded)
##   * `GIF8`                     -> raise IItermDecodeDefer
##   * `\xFF\xD8\xFF`             -> raise IItermDecodeDefer  (JPEG)
##   * everything else            -> raise IItermDecodeError
##
## A note on BMP scope. The decoder handles the most common Windows BMP
## variant only: BITMAPINFOHEADER (size==40), 24 bits per pixel,
## bottom-up scanline order, no compression (BI_RGB == 0). This is what
## a hand-built fixture or a `convert` invocation produces by default.

import std/[base64, strutils]
import ../image_types
import ./png as pngdec
export image_types

type
  IItermDecodeError* = object of CatchableError
  IItermDecodeDefer* = object of CatchableError
    ## Raised when the inner format is recognised but unsupported (PNG,
    ## JPEG, GIF). The caller can either catch + present an empty image
    ## or surface the error to the user.

# ---------------------------------------------------------------------------
# Pure-Nim 24-bit BMP decoder (uncompressed, BITMAPINFOHEADER).
# ---------------------------------------------------------------------------

proc le16(s: string; i: int): uint16 =
  uint16(byte(s[i])) or (uint16(byte(s[i + 1])) shl 8)

proc le32(s: string; i: int): uint32 =
  uint32(byte(s[i])) or
  (uint32(byte(s[i + 1])) shl 8) or
  (uint32(byte(s[i + 2])) shl 16) or
  (uint32(byte(s[i + 3])) shl 24)

proc decodeBmp(raw: string): Image =
  ## Decode a 24-bit uncompressed BMP. Returns an `Image` with
  ## `format = ifITerm2` (BMP is the carrier, the protocol is iTerm2).
  if raw.len < 14 + 40:
    raise newException(IItermDecodeError,
      "iTerm2/BMP: payload too short for BMP header (" & $raw.len & " bytes)")
  if raw[0] != 'B' or raw[1] != 'M':
    raise newException(IItermDecodeError,
      "iTerm2/BMP: missing BM signature")

  # BITMAPFILEHEADER: 14 bytes
  #  0..1  bfType        ('B','M')
  #  2..5  bfSize
  #  6..9  reserved
  # 10..13 bfOffBits     (offset to pixel data)
  let pixelOffset = int(le32(raw, 10))

  # BITMAPINFOHEADER: 40 bytes (we only handle this variant)
  # 14..17 biSize
  # 18..21 biWidth   (signed)
  # 22..25 biHeight  (signed; positive = bottom-up, negative = top-down)
  # 26..27 biPlanes  (must be 1)
  # 28..29 biBitCount
  # 30..33 biCompression  (must be 0 = BI_RGB)
  let dibSize = int(le32(raw, 14))
  if dibSize < 40:
    raise newException(IItermDecodeError,
      "iTerm2/BMP: unsupported DIB header size " & $dibSize)
  let widthRaw = int32(le32(raw, 18))
  let heightRaw = int32(le32(raw, 22))
  let planes = le16(raw, 26)
  let bpp = le16(raw, 28)
  let compression = le32(raw, 30)

  if planes != 1:
    raise newException(IItermDecodeError,
      "iTerm2/BMP: planes=" & $planes & " (must be 1)")
  if bpp != 24:
    raise newException(IItermDecodeError,
      "iTerm2/BMP: bpp=" & $bpp & " unsupported (only 24)")
  if compression != 0:
    raise newException(IItermDecodeError,
      "iTerm2/BMP: compression=" & $compression & " unsupported (must be 0)")

  let w = int(widthRaw)
  let bottomUp = heightRaw > 0
  let h = int(if bottomUp: heightRaw else: -heightRaw)
  if w <= 0 or h <= 0:
    raise newException(IItermDecodeError,
      "iTerm2/BMP: invalid dimensions " & $w & "x" & $h)
  # Each scanline is padded to a 4-byte boundary.
  let stride = ((w * 3) + 3) and (not 3)
  if pixelOffset + stride * h > raw.len:
    raise newException(IItermDecodeError,
      "iTerm2/BMP: pixel data truncated (need " & $(stride * h) &
      " bytes at offset " & $pixelOffset & ", have " & $(raw.len - pixelOffset) & ")")

  result.format = ifITerm2
  result.width = w
  result.height = h
  result.rawSize = raw.len
  result.pixels = newSeq[byte](w * h * 4)

  for y in 0 ..< h:
    let srcY = if bottomUp: (h - 1 - y) else: y
    let srcRow = pixelOffset + srcY * stride
    let dstRow = y * w * 4
    for x in 0 ..< w:
      # BMP stores BGR triples
      let b = byte(raw[srcRow + x * 3 + 0])
      let g = byte(raw[srcRow + x * 3 + 1])
      let r = byte(raw[srcRow + x * 3 + 2])
      result.pixels[dstRow + x * 4 + 0] = r
      result.pixels[dstRow + x * 4 + 1] = g
      result.pixels[dstRow + x * 4 + 2] = b
      result.pixels[dstRow + x * 4 + 3] = 0xFF

# ---------------------------------------------------------------------------
# Public entry point
# ---------------------------------------------------------------------------

proc decodeIterm2*(payload: string): Image =
  ## Decode an iTerm2 OSC 1337 payload. The input is the OSC body AFTER
  ## the `1337;` command code and BEFORE the terminator -- i.e. a string
  ## that begins with `File=...:<base64>` (or another iTerm2 command,
  ## which we reject).
  ##
  ## Raises `IItermDecodeError` for malformed input, `IItermDecodeDefer`
  ## for inner formats we recognise but don't decode (PNG, JPEG, GIF).
  if not payload.startsWith("File="):
    raise newException(IItermDecodeError,
      "iTerm2: payload does not begin with 'File='")
  let colon = payload.find(':')
  if colon < 0:
    raise newException(IItermDecodeError,
      "iTerm2: missing ':' between metadata and base64 body")
  let b64 = payload[colon + 1 .. ^1]
  let raw = base64.decode(b64)
  if raw.len == 0:
    raise newException(IItermDecodeError, "iTerm2: empty image bytes")
  if raw.len >= 4:
    if byte(raw[0]) == 0x89'u8 and raw[1] == 'P' and raw[2] == 'N' and raw[3] == 'G':
      var rawBytes = newSeq[byte](raw.len)
      for i in 0 ..< raw.len: rawBytes[i] = byte(raw[i])
      var img: Image
      try:
        img = pngdec.decodePng(rawBytes)
      except pngdec.PngDecodeError as e:
        raise newException(IItermDecodeError,
          "iTerm2/PNG decode failed: " & e.msg)
      img.format = ifITerm2
      img.rawSize = raw.len
      return img
    if raw[0] == 'G' and raw[1] == 'I' and raw[2] == 'F' and raw[3] == '8':
      raise newException(IItermDecodeDefer,
        "iTerm2: GIF inner-format -- deferred")
    if byte(raw[0]) == 0xFF'u8 and byte(raw[1]) == 0xD8'u8 and
       byte(raw[2]) == 0xFF'u8:
      raise newException(IItermDecodeDefer,
        "iTerm2: JPEG inner-format -- deferred")
  if raw.len >= 2 and raw[0] == 'B' and raw[1] == 'M':
    return decodeBmp(raw)
  raise newException(IItermDecodeError,
    "iTerm2: unrecognised inner image format (first bytes: " &
    $byte(raw[0]) & " " & $byte(raw[1]) & " " & $byte(raw[2]) & ")")
