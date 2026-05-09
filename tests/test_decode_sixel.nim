## test_decode_sixel.nim -- exact-byte test for the Sixel decoder.
##
## Fixture A: a hand-rolled solid-blue 4x6 image.
##   `#1;2;0;0;100`  -- define pen 1 as RGB(0%, 0%, 100%) = blue.
##   `#1`            -- select pen 1.
##   `~~~~`          -- four columns; each `~` = 0x7E - 0x3F = 63 = 0b111111
##                       (all six band-rows lit).
##
## Fixture B: a two-band, two-colour image with run-length compression.
##   `"1;1;6;12`     -- raster attrs: width=6, height=12.
##   `#1;2;100;0;0#2;2;0;100;0`  -- pen 1 = red, pen 2 = green.
##   `#1!6~`         -- first band: 6 columns of red.
##   `-`             -- next band.
##   `#2!6~`         -- second band: 6 columns of green.

import nim_libvterm/decoders/sixel

proc fnv1a(b: openArray[byte]): uint64 =
  result = 0xcbf29ce484222325'u64
  for x in b:
    result = result xor uint64(x)
    result = result * 0x100000001b3'u64

block solid_blue_4x6:
  let payload = "#1;2;0;0;100#1~~~~"
  let img = decodeSixel(payload)
  doAssert img.format == ifSixel
  doAssert img.width == 4
  doAssert img.height == 6
  doAssert img.pixels.len == 4 * 6 * 4

  # First pixel
  doAssert img.pixels[0] == 0
  doAssert img.pixels[1] == 0
  doAssert img.pixels[2] == 255
  doAssert img.pixels[3] == 255

  # Middle (pixel index 12 = (3, 0) = row 3, col 0)
  let mid = (3 * 4 + 0) * 4
  doAssert img.pixels[mid + 0] == 0
  doAssert img.pixels[mid + 1] == 0
  doAssert img.pixels[mid + 2] == 255
  doAssert img.pixels[mid + 3] == 255

  # Last pixel: (5, 3)
  let last = (5 * 4 + 3) * 4
  doAssert img.pixels[last + 0] == 0
  doAssert img.pixels[last + 1] == 0
  doAssert img.pixels[last + 2] == 255
  doAssert img.pixels[last + 3] == 255

  let h = fnv1a(img.pixels)
  doAssert h == 0xbb9e692b79a3d135'u64,
    "sixel solid-blue hash mismatch: " & $h

block two_band_run_length:
  let payload = "\"1;1;6;12#1;2;100;0;0#2;2;0;100;0#1!6~-#2!6~"
  let img = decodeSixel(payload)
  doAssert img.format == ifSixel
  doAssert img.width == 6
  doAssert img.height == 12, "got height=" & $img.height
  doAssert img.pixels.len == 6 * 12 * 4

  # First pixel red
  doAssert img.pixels[0] == 255
  doAssert img.pixels[1] == 0
  doAssert img.pixels[2] == 0
  doAssert img.pixels[3] == 255

  # Middle of band 1 row 5 = top half last red row
  let mid = (5 * 6 + 3) * 4
  doAssert img.pixels[mid + 0] == 255
  doAssert img.pixels[mid + 1] == 0
  doAssert img.pixels[mid + 2] == 0

  # Band 2: row 6 (first green row), col 0
  let b2 = (6 * 6 + 0) * 4
  doAssert img.pixels[b2 + 0] == 0
  doAssert img.pixels[b2 + 1] == 255
  doAssert img.pixels[b2 + 2] == 0
  doAssert img.pixels[b2 + 3] == 255

  # Last pixel: row 11, col 5 (green)
  let last = (11 * 6 + 5) * 4
  doAssert img.pixels[last + 0] == 0
  doAssert img.pixels[last + 1] == 255
  doAssert img.pixels[last + 2] == 0
  doAssert img.pixels[last + 3] == 255

  let h = fnv1a(img.pixels)
  doAssert h == 0x8c1d695659d093fd'u64,
    "sixel run-length hash mismatch: " & $h

echo "test_decode_sixel OK"
