## test_decode_gif_rgba.nim -- exact-byte test for the stb_image-backed
## GIF decode path (exposed via the `decodePng` wrapper which is now a
## generic stb_image entry point).
##
## GIF is lossless (palette-indexed); every pixel in the reference RGBA
## output matches the palette entry exactly, so we assert byte-equal.

import nim_libvterm/decoders/png as pngdec
import ./fixtures_jpeg_gif

block decode_solid_red_gif_4x4:
  let img = pngdec.decodePng(SolidRedGif4x4)
  doAssert img.width == 4, "width=" & $img.width
  doAssert img.height == 4, "height=" & $img.height
  doAssert img.pixels.len == 4 * 4 * 4
  for i in 0 ..< 4 * 4:
    let o = i * 4
    doAssert img.pixels[o + 0] == 0xFF'u8
    doAssert img.pixels[o + 1] == 0x00'u8
    doAssert img.pixels[o + 2] == 0x00'u8
    doAssert img.pixels[o + 3] == 0xFF'u8

block decode_4colour_gif_2x2:
  ## Layout (from the ImageMagick generation recipe):
  ##   (0,0) red       (255,0,0)
  ##   (1,0) green     (  0,128,0)   -- HTML "green" is dark green
  ##   (0,1) blue      (  0,  0,255)
  ##   (1,1) white     (255,255,255)
  let img = pngdec.decodePng(Colors2x2Gif)
  doAssert img.width == 2
  doAssert img.height == 2
  doAssert img.pixels.len == 16

  proc px(x, y: int): array[4, byte] =
    let o = (y * 2 + x) * 4
    [img.pixels[o], img.pixels[o + 1], img.pixels[o + 2], img.pixels[o + 3]]

  doAssert px(0, 0) == [0xFF'u8, 0x00, 0x00, 0xFF]
  doAssert px(1, 0) == [0x00'u8, 0x80, 0x00, 0xFF]
  doAssert px(0, 1) == [0x00'u8, 0x00, 0xFF, 0xFF]
  doAssert px(1, 1) == [0xFF'u8, 0xFF, 0xFF, 0xFF]

echo "test_decode_gif_rgba OK"
