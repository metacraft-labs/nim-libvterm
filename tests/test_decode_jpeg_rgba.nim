## test_decode_jpeg_rgba.nim -- exact-byte test for the stb_image-backed
## JPEG decode path (exposed via the `decodePng` wrapper which is now a
## generic stb_image entry point).
##
## JPEG is lossy: ImageMagick at -quality 95 produces R=0xFE,G=0,B=0 for
## a solid-red 8x8 source. We assert that exact reference output (it's
## what stb_image produces and what ImageMagick produces; both pass
## through the same JPEG quantisation tables).

import nim_libvterm/decoders/png as pngdec
import ./fixtures_jpeg_gif

block decode_solid_red_jpeg:
  let img = pngdec.decodePng(SolidRedJpeg8x8)
  doAssert img.width == 8, "width=" & $img.width
  doAssert img.height == 8, "height=" & $img.height
  doAssert img.pixels.len == 8 * 8 * 4
  # Every pixel: R=0xFE (lossy quantisation), G=0, B=0, A=0xFF.
  for i in 0 ..< 8 * 8:
    let o = i * 4
    doAssert img.pixels[o + 0] == 0xFE'u8,
      "pixel " & $i & " R=" & $img.pixels[o + 0]
    doAssert img.pixels[o + 1] == 0'u8,
      "pixel " & $i & " G=" & $img.pixels[o + 1]
    doAssert img.pixels[o + 2] == 0'u8,
      "pixel " & $i & " B=" & $img.pixels[o + 2]
    doAssert img.pixels[o + 3] == 0xFF'u8,
      "pixel " & $i & " A=" & $img.pixels[o + 3]
  doAssert img.rawSize == SolidRedJpeg8x8.len

block decode_colors_jpeg_dimensions:
  ## A 4-colour 2x2 JPEG: dimension/format check only (per-pixel exact
  ## values are sensitive to JPEG quantisation tables; we exercise exact
  ## pixel values in the GIF test which is lossless).
  let img = pngdec.decodePng(Colors2x2Jpeg)
  doAssert img.width == 2
  doAssert img.height == 2
  doAssert img.pixels.len == 16
  # Alpha must always be 0xFF for a JPEG (no alpha channel in source).
  for y in 0 ..< 2:
    for x in 0 ..< 2:
      let o = (y * 2 + x) * 4
      doAssert img.pixels[o + 3] == 0xFF'u8

echo "test_decode_jpeg_rgba OK"
