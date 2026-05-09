## test_dcs_sixel_ingest.nim -- end-to-end DCS (Sixel) ingestion test.
##
## Drives a complete Sixel byte sequence (DCS-wrapped, ST-terminated)
## through the public `Screen.feed()` API. Asserts the screen registers
## exactly one image whose decoded RGBA pixels match the expected
## buffer -- proving the parser->state-fallback->Nim handler->decoder
## pipeline is wired end-to-end.
##
## The fixture is the same "solid blue 4x6" payload the unit test in
## `test_decode_sixel.nim` uses, but here we drive it through the libvterm
## DCS state machine instead of calling the decoder directly.

import std/options
import nim_libvterm

block solid_blue_4x6_through_dcs:
  var s = newScreen(10, 40)
  doAssert s.images().len == 0

  # `\x1bP` -- DCS introducer.
  # `q`     -- final byte that triggers entry into DCS data state. Sixel
  #            uses `q` (0x71) and may have semicolon-separated params
  #            before it (here we use no params, just `q`).
  # body    -- `#1;2;0;0;100#1~~~~`: define pen 1 = blue (RGB 0%,0%,100%),
  #            select pen 1, paint 4 columns of full-band.
  # `\x1b\` -- ST terminator.
  let payload = "\x1bPq#1;2;0;0;100#1~~~~\x1b\\"
  s.feed(payload)

  let imgs = s.images()
  doAssert imgs.len == 1, "expected one image, got " & $imgs.len

  let img = s.imageData(imgs[0])
  doAssert img.format == ifSixel, "format=" & $img.format
  doAssert img.width == 4, "width=" & $img.width
  doAssert img.height == 6, "height=" & $img.height
  doAssert img.pixels.len == 4 * 6 * 4,
    "pixels.len=" & $img.pixels.len

  # First pixel: solid blue (B=255).
  doAssert img.pixels[0] == 0
  doAssert img.pixels[1] == 0
  doAssert img.pixels[2] == 255
  doAssert img.pixels[3] == 255

  # Last pixel: (5, 3) -- still blue.
  let last = (5 * 4 + 3) * 4
  doAssert img.pixels[last + 0] == 0
  doAssert img.pixels[last + 1] == 0
  doAssert img.pixels[last + 2] == 255
  doAssert img.pixels[last + 3] == 255

  # The image registers a placement at the cursor position (0, 0). Since
  # 4x6 px ÷ 8x16 cells rounds up to a 1x1 cell footprint, cell (0, 0)
  # maps back to the registered ImageRef.
  let ref0 = s.imageAt(0, 0)
  doAssert ref0.isSome, "expected imageAt(0,0) to be populated"
  doAssert ref0.get == imgs[0]

block sixel_with_params_q:
  ## Exercise the param-prefixed DCS form: `\x1bP 0;0;8q ... \x1b\`. This
  ## confirms the DCS-command-byte capture (we route on the *final* byte,
  ## not the leader bytes).
  var s = newScreen(10, 40)
  let payload = "\x1bP0;0;8q\"1;1;6;12#1;2;100;0;0#2;2;0;100;0#1!6~-#2!6~\x1b\\"
  s.feed(payload)
  let imgs = s.images()
  doAssert imgs.len == 1, "expected one image, got " & $imgs.len
  let img = s.imageData(imgs[0])
  doAssert img.format == ifSixel
  doAssert img.width == 6
  doAssert img.height == 12
  doAssert img.pixels.len == 6 * 12 * 4
  # First pixel red.
  doAssert img.pixels[0] == 255
  doAssert img.pixels[1] == 0
  doAssert img.pixels[2] == 0
  # Band 2 first pixel -- green.
  let b2 = (6 * 6 + 0) * 4
  doAssert img.pixels[b2 + 0] == 0
  doAssert img.pixels[b2 + 1] == 255
  doAssert img.pixels[b2 + 2] == 0

echo "test_dcs_sixel_ingest OK"
