## test_decode_iterm2.nim -- exact-byte test for the iTerm2 OSC 1337
## inline-image decoder.
##
## We hand-build a 24-bit uncompressed BMP fixture (3 pixels wide, 2
## tall) with a known colour pattern, base64-encode it, wrap in the
## iTerm2 `File=...:<b64>` envelope, and feed it through `decodeIterm2`.
##
## stb_image now backs every inner-format path; what used to be the
## "PNG/JPEG/GIF deferred" cases are exercised by sibling tests
## (`test_iterm2_png_decode.nim`, `test_iterm2_jpeg_decode.nim`,
## `test_iterm2_gif_decode.nim`). What remains here is the BMP fixture
## (which still goes through stb_image now) and a malformed-input case
## that proves the decoder fails CLEANLY rather than crashing.

import std/base64
import nim_libvterm/decoders/iterm2

proc fnv1a(b: openArray[byte]): uint64 =
  result = 0xcbf29ce484222325'u64
  for x in b:
    result = result xor uint64(x)
    result = result * 0x100000001b3'u64

proc le16(out_arr: var seq[byte]; v: uint16) =
  out_arr.add byte(v and 0xFF)
  out_arr.add byte((v shr 8) and 0xFF)

proc le32(out_arr: var seq[byte]; v: uint32) =
  out_arr.add byte(v and 0xFF)
  out_arr.add byte((v shr 8) and 0xFF)
  out_arr.add byte((v shr 16) and 0xFF)
  out_arr.add byte((v shr 24) and 0xFF)

proc buildBmp(w, h: int; rows: seq[seq[(byte, byte, byte)]]): seq[byte] =
  ## Build a Windows-style 24-bit uncompressed BMP. `rows[0]` is the TOP
  ## row of the image, but BMP stores bottom-up, so we'll reverse here.
  let stride = ((w * 3) + 3) and (not 3)
  let pixelOffset = 14 + 40
  let pixelBytes = stride * h
  result = @[]

  # BITMAPFILEHEADER (14 bytes)
  result.add byte('B')
  result.add byte('M')
  le32(result, uint32(pixelOffset + pixelBytes))   # bfSize
  le16(result, 0)                                  # reserved1
  le16(result, 0)                                  # reserved2
  le32(result, uint32(pixelOffset))                # bfOffBits

  # BITMAPINFOHEADER (40 bytes)
  le32(result, 40)                                 # biSize
  le32(result, uint32(w))                          # biWidth
  le32(result, uint32(h))                          # biHeight (positive => bottom-up)
  le16(result, 1)                                  # biPlanes
  le16(result, 24)                                 # biBitCount
  le32(result, 0)                                  # biCompression (BI_RGB)
  le32(result, uint32(pixelBytes))                 # biSizeImage
  le32(result, 2835)                               # biXPelsPerMeter (~72 DPI)
  le32(result, 2835)                               # biYPelsPerMeter
  le32(result, 0)                                  # biClrUsed
  le32(result, 0)                                  # biClrImportant

  # Pixel data, bottom-up. `rows[0]` is the visual top, so write rows[h-1]
  # first.
  for y in countdown(h - 1, 0):
    var written = 0
    for x in 0 ..< w:
      let (r, g, b) = rows[y][x]
      result.add b
      result.add g
      result.add r
      written += 3
    while written < stride:
      result.add 0
      inc written

block bmp_3x2:
  # Visual layout (top-to-bottom):
  #   row 0: red, green, blue
  #   row 1: white, gray(128), black
  let rows: seq[seq[(byte, byte, byte)]] = @[
    @[(255'u8, 0'u8, 0'u8), (0'u8, 255'u8, 0'u8), (0'u8, 0'u8, 255'u8)],
    @[(255'u8, 255'u8, 255'u8), (128'u8, 128'u8, 128'u8), (0'u8, 0'u8, 0'u8)],
  ]
  let bmp = buildBmp(3, 2, rows)
  # Convert seq[byte] to string.
  var bmpStr = newString(bmp.len)
  for i in 0 ..< bmp.len:
    bmpStr[i] = char(bmp[i])
  let b64 = base64.encode(bmpStr)
  let payload = "File=name=test.bmp;inline=1:" & b64

  let img = decodeIterm2(payload)
  doAssert img.format == ifITerm2
  doAssert img.width == 3
  doAssert img.height == 2
  doAssert img.pixels.len == 24

  # First pixel: (0,0) red.
  doAssert img.pixels[0] == 255
  doAssert img.pixels[1] == 0
  doAssert img.pixels[2] == 0
  doAssert img.pixels[3] == 255

  # Middle pixel: (1, 1) gray (128,128,128).
  let mid = (1 * 3 + 1) * 4
  doAssert img.pixels[mid + 0] == 128
  doAssert img.pixels[mid + 1] == 128
  doAssert img.pixels[mid + 2] == 128
  doAssert img.pixels[mid + 3] == 255

  # Last pixel: (1, 2) black.
  let last = (1 * 3 + 2) * 4
  doAssert img.pixels[last + 0] == 0
  doAssert img.pixels[last + 1] == 0
  doAssert img.pixels[last + 2] == 0
  doAssert img.pixels[last + 3] == 255

  # Sanity-check: FNV1a hash over decoded pixels is non-zero (the BMP
  # decoder produced *some* output, not all zeros). We do not assert a
  # specific hash because the exact byte layout for stride padding /
  # row order is an implementation detail of stb_image.
  let h = fnv1a(img.pixels)
  doAssert h != 0'u64

block png_truncated_now_errors:
  # PNG magic bytes only -- decoder should attempt to parse it and
  # reject the truncated payload via IItermDecodeError. We keep this
  # case around to prove the decoder fails CLEANLY rather than crashing
  # on under-sized input.
  let pngBytes = [0x89'u8, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
                  0x00, 0x00, 0x00, 0x00]  # truncated
  var pngStr = newString(pngBytes.len)
  for i in 0 ..< pngBytes.len: pngStr[i] = char(pngBytes[i])
  let payload = "File=name=test.png;inline=1:" & base64.encode(pngStr)
  var raised = false
  try:
    discard decodeIterm2(payload)
  except IItermDecodeError:
    raised = true
  doAssert raised, "expected IItermDecodeError for truncated PNG"

block truncated_jpeg_errors:
  # JPEG SOI (FF D8 FF) followed by JFIF header but no scan data -- not
  # a complete image; stb_image rejects, decodeIterm2 surfaces it as
  # IItermDecodeError.
  let jpegBytes = [0xFF'u8, 0xD8, 0xFF, 0xE0, 0, 16, byte('J'),
                   byte('F'), byte('I'), byte('F'), 0]
  var jpegStr = newString(jpegBytes.len)
  for i in 0 ..< jpegBytes.len: jpegStr[i] = char(jpegBytes[i])
  let payload = "File=name=test.jpg;inline=1:" & base64.encode(jpegStr)
  var raised = false
  try:
    discard decodeIterm2(payload)
  except IItermDecodeError:
    raised = true
  doAssert raised, "expected IItermDecodeError for truncated JPEG"

echo "test_decode_iterm2 OK"
