## test_decode_png_rgb.nim -- exact-byte test for the PNG decoder, RGB
## (color type 2) path.
##
## Color type 2 PNGs are 3 bytes per pixel; the decoder must expand them
## to RGBA with alpha forced to 255.

import nim_libvterm/decoders/png
import ./test_helpers

const W = 3
const H = 2

block decode_rgb_3x2:
  # Visual:
  #   row 0: red, green, blue
  #   row 1: white, gray(128), black
  let pixels: seq[byte] = @[
    255'u8, 0,   0,   # red
    0'u8,   255, 0,   # green
    0'u8,   0,   255, # blue
    255'u8, 255, 255, # white
    128'u8, 128, 128, # gray
    0'u8,   0,   0,   # black
  ]
  let pngBytes = encodePng(W, H, 2, pixels)
  let img = decodePng(pngBytes)
  doAssert img.width == W
  doAssert img.height == H
  doAssert img.pixels.len == W * H * 4

  proc px(x, y: int): array[4, byte] =
    let o = (y * W + x) * 4
    [img.pixels[o], img.pixels[o + 1], img.pixels[o + 2], img.pixels[o + 3]]

  doAssert px(0, 0) == [255'u8, 0, 0, 255]
  doAssert px(1, 0) == [0'u8, 255, 0, 255]
  doAssert px(2, 0) == [0'u8, 0, 255, 255]
  doAssert px(0, 1) == [255'u8, 255, 255, 255]
  doAssert px(1, 1) == [128'u8, 128, 128, 255]
  doAssert px(2, 1) == [0'u8, 0, 0, 255]

  # Confirm alpha=255 was synthesised, not pulled from the source.
  for y in 0 ..< H:
    for x in 0 ..< W:
      let alphaOff = (y * W + x) * 4 + 3
      doAssert img.pixels[alphaOff] == 0xFF'u8

echo "test_decode_png_rgb OK"
