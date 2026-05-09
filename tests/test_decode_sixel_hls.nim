## test_decode_sixel_hls.nim -- exact-byte tests for the Sixel HLS palette
## arm.
##
## Sixel supports two palette syntaxes:
##   * `#<n>;2;R;G;B` -- RGB on the 0..100 scale (already covered by
##     `test_decode_sixel.nim`).
##   * `#<n>;1;H;L;S` -- HLS with H ∈ [0, 360°], L ∈ [0, 100],
##     S ∈ [0, 100] (this file).
##
## Each block hand-rolls a Sixel byte stream that defines a pen via the
## HLS form, selects the pen, paints a 4×6 region with `~` (= bits
## 0b111111, all six band-rows lit), and asserts the resulting RGBA
## pixels match the reference HLS-to-RGB conversion.
##
## Reference test vectors (from the canonical algorithm):
##   HLS (0, 0, 0)        -> RGB (0, 0, 0)         pure black
##   HLS (0, 100, 0)      -> RGB (255, 255, 255)   pure white
##   HLS (0, 50, 100)     -> RGB (255, 0, 0)       saturated red
##   HLS (120, 50, 100)   -> RGB (0, 255, 0)       saturated green
##   HLS (240, 50, 100)   -> RGB (0, 0, 255)       saturated blue
##   HLS (0, 50, 0)       -> RGB (128, 128, 128)   neutral grey (S=0)

import nim_libvterm/decoders/sixel

proc assertSolid(img: Image; w, h: int; r, g, b: uint8; tag: string) =
  ## Assert every pixel in `img` matches RGBA (r, g, b, 255).
  doAssert img.format == ifSixel, tag & ": format=" & $img.format
  doAssert img.width == w, tag & ": width=" & $img.width
  doAssert img.height == h, tag & ": height=" & $img.height
  doAssert img.pixels.len == w * h * 4,
    tag & ": pixels.len=" & $img.pixels.len
  for y in 0 ..< h:
    for x in 0 ..< w:
      let p = (y * w + x) * 4
      doAssert img.pixels[p + 0] == r,
        tag & " R mismatch at (" & $x & "," & $y & ")=" & $img.pixels[p + 0]
      doAssert img.pixels[p + 1] == g,
        tag & " G mismatch at (" & $x & "," & $y & ")=" & $img.pixels[p + 1]
      doAssert img.pixels[p + 2] == b,
        tag & " B mismatch at (" & $x & "," & $y & ")=" & $img.pixels[p + 2]
      doAssert img.pixels[p + 3] == 255,
        tag & " A mismatch at (" & $x & "," & $y & ")=" & $img.pixels[p + 3]

block hls_red_4x6:
  ## HLS (0, 50, 100) -> red. Pen 0, raster-attrs-less form.
  let payload = "#0;1;0;50;100#0~~~~"
  let img = decodeSixel(payload)
  assertSolid(img, 4, 6, 255'u8, 0'u8, 0'u8, "hls_red")

block hls_green_4x6:
  ## HLS (120, 50, 100) -> green.
  let payload = "#0;1;120;50;100#0~~~~"
  let img = decodeSixel(payload)
  assertSolid(img, 4, 6, 0'u8, 255'u8, 0'u8, "hls_green")

block hls_blue_4x6:
  ## HLS (240, 50, 100) -> blue.
  let payload = "#0;1;240;50;100#0~~~~"
  let img = decodeSixel(payload)
  assertSolid(img, 4, 6, 0'u8, 0'u8, 255'u8, "hls_blue")

block hls_white_4x6:
  ## HLS (0, 100, 0) -> white. Saturation=0 so the hue is irrelevant.
  let payload = "#0;1;0;100;0#0~~~~"
  let img = decodeSixel(payload)
  assertSolid(img, 4, 6, 255'u8, 255'u8, 255'u8, "hls_white")

block hls_black_4x6:
  ## HLS (0, 0, 0) -> black.
  let payload = "#0;1;0;0;0#0~~~~"
  let img = decodeSixel(payload)
  assertSolid(img, 4, 6, 0'u8, 0'u8, 0'u8, "hls_black")

block hls_grey_4x6:
  ## HLS (0, 50, 0) -> mid-grey. Saturation=0 short-circuits to a pure
  ## L-driven grey; verifies the S=0 fast path.
  let payload = "#0;1;0;50;0#0~~~~"
  let img = decodeSixel(payload)
  assertSolid(img, 4, 6, 128'u8, 128'u8, 128'u8, "hls_grey")

block mixed_hls_and_rgb_palettes:
  ## Two-band image: pen 0 defined via HLS (red), pen 1 defined via RGB
  ## (green). First band paints with pen 0, second band with pen 1. This
  ## proves the HLS arm doesn't disturb the RGB arm or vice versa.
  let payload =
    "\"1;1;6;12" &        # raster attrs: width=6, height=12
    "#0;1;0;50;100" &     # pen 0 = HLS (0, 50, 100) = red
    "#1;2;0;100;0" &      # pen 1 = RGB (0%, 100%, 0%) = green
    "#0!6~" &             # band 0: 6 columns of red
    "-" &                 # next band
    "#1!6~"               # band 1: 6 columns of green
  let img = decodeSixel(payload)
  doAssert img.format == ifSixel
  doAssert img.width == 6, "width=" & $img.width
  doAssert img.height == 12, "height=" & $img.height
  doAssert img.pixels.len == 6 * 12 * 4

  # Top band (rows 0..5) -- red.
  for y in 0 .. 5:
    for x in 0 ..< 6:
      let p = (y * 6 + x) * 4
      doAssert img.pixels[p + 0] == 255,
        "red band R at (" & $x & "," & $y & ")=" & $img.pixels[p + 0]
      doAssert img.pixels[p + 1] == 0,
        "red band G at (" & $x & "," & $y & ")=" & $img.pixels[p + 1]
      doAssert img.pixels[p + 2] == 0,
        "red band B at (" & $x & "," & $y & ")=" & $img.pixels[p + 2]
      doAssert img.pixels[p + 3] == 255

  # Bottom band (rows 6..11) -- green.
  for y in 6 .. 11:
    for x in 0 ..< 6:
      let p = (y * 6 + x) * 4
      doAssert img.pixels[p + 0] == 0,
        "green band R at (" & $x & "," & $y & ")=" & $img.pixels[p + 0]
      doAssert img.pixels[p + 1] == 255,
        "green band G at (" & $x & "," & $y & ")=" & $img.pixels[p + 1]
      doAssert img.pixels[p + 2] == 0,
        "green band B at (" & $x & "," & $y & ")=" & $img.pixels[p + 2]
      doAssert img.pixels[p + 3] == 255

block hls_to_rgb_unit_vectors:
  ## Direct unit-test of `hlsToRgb` against the canonical reference
  ## vectors documented in the proc body. This complements the
  ## decoder-level tests above by isolating the conversion from the
  ## state machine.
  doAssert hlsToRgb(0, 0, 0) == (0'u8, 0'u8, 0'u8)
  doAssert hlsToRgb(0, 100, 0) == (255'u8, 255'u8, 255'u8)
  doAssert hlsToRgb(0, 50, 100) == (255'u8, 0'u8, 0'u8)
  doAssert hlsToRgb(120, 50, 100) == (0'u8, 255'u8, 0'u8)
  doAssert hlsToRgb(240, 50, 100) == (0'u8, 0'u8, 255'u8)
  doAssert hlsToRgb(0, 50, 0) == (128'u8, 128'u8, 128'u8)

echo "test_decode_sixel_hls OK"
