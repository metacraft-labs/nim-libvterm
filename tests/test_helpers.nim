## tests/test_helpers.nim -- shared utilities for the test suite.
##
## NB: this file does NOT begin with `test_` so the Justfile's recipe
## list won't pick it up as a runnable test. Tests `import` this module
## with `import ./test_helpers` style relative paths.

import std/[strutils, unicode]
import nim_libvterm
import nim_libvterm/zlib_ffi

template feedAll*(s: var Screen; bytes: openArray[string]) =
  ## Feed each fragment in turn -- handy for verifying that fragmented
  ## OSCs are reassembled correctly.
  for b in bytes:
    s.feed(b)

proc rowAsString*(s: Screen; row: int): string =
  ## Return the visible rune contents of one row, with trailing blanks
  ## trimmed.
  let n = s.size().cols
  result = newStringOfCap(n)
  for c in 0 ..< n:
    let r = s.cellAt(row, c).rune
    if uint32(r) == 0'u32:
      result.add ' '
    else:
      var buf: string
      buf.add r
      result.add buf
  result = result.strip(leading = false, trailing = true)

proc be32Bytes*(out_arr: var seq[byte]; v: uint32) =
  ## Append a big-endian uint32 (PNG byte order).
  out_arr.add byte((v shr 24) and 0xFF)
  out_arr.add byte((v shr 16) and 0xFF)
  out_arr.add byte((v shr 8) and 0xFF)
  out_arr.add byte(v and 0xFF)

proc emitPngChunk*(out_arr: var seq[byte]; chunkType: string;
                   data: openArray[byte]) =
  ## Append a complete PNG chunk: 4-byte length, 4-byte type, payload,
  ## 4-byte CRC32 (over type + payload). `chunkType` must be exactly 4
  ## ASCII characters per the spec.
  doAssert chunkType.len == 4
  be32Bytes(out_arr, uint32(data.len))
  var typeBytes: array[4, byte]
  for i in 0 .. 3:
    typeBytes[i] = byte(chunkType[i])
    out_arr.add typeBytes[i]
  for b in data:
    out_arr.add b
  var crc = crc32Update(0'u32, typeBytes)
  if data.len > 0:
    crc = crc32Update(crc, data)
  be32Bytes(out_arr, crc)

proc encodePng*(width, height: int; colorType: int;
                pixels: openArray[byte]): seq[byte] =
  ## Build a valid uncompressed-style PNG (filter type None on every
  ## scanline) with the given color type.
  ##
  ## `colorType` accepts 2 (RGB, 3 bytes/pixel) or 6 (RGBA, 4 bytes/pixel).
  ## `pixels` is the raw unfiltered pixel buffer in row-major order.
  doAssert colorType == 2 or colorType == 6
  let bpp = if colorType == 6: 4 else: 3
  doAssert pixels.len == width * height * bpp,
    "encodePng: pixels.len=" & $pixels.len &
    " mismatches width*height*bpp=" & $(width * height * bpp)

  result = @[]
  # Signature.
  for b in [0x89'u8, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]:
    result.add b

  # IHDR.
  var ihdr: seq[byte] = @[]
  be32Bytes(ihdr, uint32(width))
  be32Bytes(ihdr, uint32(height))
  ihdr.add 8'u8                  # bit depth
  ihdr.add byte(colorType)
  ihdr.add 0'u8                  # compression method (deflate)
  ihdr.add 0'u8                  # filter method (default)
  ihdr.add 0'u8                  # interlace = none
  emitPngChunk(result, "IHDR", ihdr)

  # IDAT: filter byte 0 (None) prepended to each scanline, then deflate.
  var raw = newSeq[byte](height * (1 + width * bpp))
  var rOff = 0
  for y in 0 ..< height:
    raw[rOff] = 0  # filter type = None
    inc rOff
    for k in 0 ..< width * bpp:
      raw[rOff + k] = pixels[y * width * bpp + k]
    rOff += width * bpp
  let compressed = deflateBytes(raw)
  emitPngChunk(result, "IDAT", compressed)

  # IEND (zero-length payload).
  emitPngChunk(result, "IEND", [])

proc esc*(s: string): string =
  ## Replace `\\x1b` and `\\x07` shorthand with the actual control bytes.
  result = newStringOfCap(s.len)
  var i = 0
  while i < s.len:
    if i + 3 < s.len and s[i] == '\\' and s[i + 1] == 'x':
      let hex = s[i + 2 .. i + 3]
      result.add char(parseHexInt(hex))
      i += 4
    elif i + 1 < s.len and s[i] == '\\' and s[i + 1] == 'e':
      result.add '\x1b'
      i += 2
    else:
      result.add s[i]
      i += 1
