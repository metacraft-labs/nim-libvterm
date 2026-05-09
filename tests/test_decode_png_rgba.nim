## test_decode_png_rgba.nim -- exact-byte test for the pure-Nim PNG
## decoder, RGBA (color type 6) path.
##
## Builds a 4x4 RGBA PNG from a known pixel pattern using `encodePng`
## (which round-trips through the same zlib-FFI layer the decoder uses),
## then decodes it and asserts every pixel matches.
##
## Also exercises the "decode->reencode->decode" round-trip to catch
## cases where the decoder masks an encoder bug or vice versa.

import nim_libvterm/decoders/png
import ./test_helpers

const W = 4
const H = 4

proc setPx(buf: var seq[byte]; x, y: int; r, g, b, a: byte) =
  let o = (y * W + x) * 4
  buf[o + 0] = r
  buf[o + 1] = g
  buf[o + 2] = b
  buf[o + 3] = a

proc buildRgbaPattern(): seq[byte] =
  ## Produces a 4x4 image:
  ##   row 0: red, green, blue, white
  ##   row 1: 50% red, 50% green, 50% blue, 50% white
  ##   row 2: black, dark red, dark green, dark blue
  ##   row 3: alpha-fade column gradient
  result = newSeq[byte](W * H * 4)
  setPx(result, 0, 0, 255, 0,   0,   255)
  setPx(result, 1, 0, 0,   255, 0,   255)
  setPx(result, 2, 0, 0,   0,   255, 255)
  setPx(result, 3, 0, 255, 255, 255, 255)
  setPx(result, 0, 1, 128, 0,   0,   255)
  setPx(result, 1, 1, 0,   128, 0,   255)
  setPx(result, 2, 1, 0,   0,   128, 255)
  setPx(result, 3, 1, 128, 128, 128, 255)
  setPx(result, 0, 2, 0,   0,   0,   255)
  setPx(result, 1, 2, 64,  0,   0,   255)
  setPx(result, 2, 2, 0,   64,  0,   255)
  setPx(result, 3, 2, 0,   0,   64,  255)
  setPx(result, 0, 3, 200, 100, 50,  0)
  setPx(result, 1, 3, 200, 100, 50,  85)
  setPx(result, 2, 3, 200, 100, 50,  170)
  setPx(result, 3, 3, 200, 100, 50,  255)

block decode_rgba_4x4:
  let original = buildRgbaPattern()
  let pngBytes = encodePng(W, H, 6, original)
  doAssert pngBytes.len > 8 + 25 + 12
  # Verify the signature so we know `encodePng` actually emitted a PNG.
  doAssert pngBytes[0] == 0x89'u8
  doAssert pngBytes[1] == byte('P')
  doAssert pngBytes[2] == byte('N')
  doAssert pngBytes[3] == byte('G')

  let img = decodePng(pngBytes)
  doAssert img.width == W, "width=" & $img.width
  doAssert img.height == H, "height=" & $img.height
  doAssert img.pixels.len == W * H * 4
  for i in 0 ..< original.len:
    doAssert img.pixels[i] == original[i],
      "pixel byte " & $i & " mismatch: got " & $img.pixels[i] &
      ", expected " & $original[i]

block decode_rgba_round_trip:
  let original = buildRgbaPattern()
  let png1 = encodePng(W, H, 6, original)
  let img1 = decodePng(png1)
  let png2 = encodePng(W, H, 6, img1.pixels)
  let img2 = decodePng(png2)
  doAssert img2.pixels == img1.pixels
  doAssert img2.pixels == original

echo "test_decode_png_rgba OK"
