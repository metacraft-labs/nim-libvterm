## test_apc_kitty_ingest.nim -- end-to-end APC (Kitty graphics) ingestion
## test.
##
## Drives a complete Kitty graphics APC sequence (`\x1b_G<header>;<base64>
## \x1b\\`) through the public `Screen.feed()` API. Asserts the screen
## registers exactly one image whose decoded RGBA pixels match the
## expected buffer -- proving the parser->state-fallback->Nim
## handler->decoder pipeline is wired end-to-end for Kitty `f=32`.

import std/[base64, options]
import nim_libvterm

const W = 4
const H = 4

proc buildRgba(): seq[byte] =
  ## Same checkerboard fixture used by `test_decode_kitty_rgba.nim`.
  result = newSeq[byte](W * H * 4)
  for y in 0 ..< H:
    for x in 0 ..< W:
      let p = (y * W + x) * 4
      if ((x + y) and 1) == 0:
        result[p + 0] = 255  # red
        result[p + 1] = 0
        result[p + 2] = 0
        result[p + 3] = 255
      else:
        result[p + 0] = 0    # green
        result[p + 1] = 255
        result[p + 2] = 0
        result[p + 3] = 255

block kitty_f32_through_apc:
  let raw = buildRgba()
  var asString = newString(raw.len)
  for i in 0 ..< raw.len:
    asString[i] = char(raw[i])
  let b64 = base64.encode(asString)

  # Kitty graphics APC envelope:
  #   `\x1b_G<header>;<data>\x1b\\`
  # Header is comma-separated key=value: a=T (transmit-and-display),
  # f=32 (RGBA), s=4, v=4 (4x4 image), i=1 (image id).
  let payload = "\x1b_Ga=T,f=32,s=4,v=4,i=1;" & b64 & "\x1b\\"

  var s = newScreen(10, 40)
  doAssert s.images().len == 0
  s.feed(payload)

  let imgs = s.images()
  doAssert imgs.len == 1, "expected one image, got " & $imgs.len

  let img = s.imageData(imgs[0])
  doAssert img.format == ifKitty, "format=" & $img.format
  doAssert img.width == W
  doAssert img.height == H
  doAssert img.pixels.len == W * H * 4

  # First pixel: (0,0) -- red.
  doAssert img.pixels[0] == 255
  doAssert img.pixels[1] == 0
  doAssert img.pixels[2] == 0
  doAssert img.pixels[3] == 255

  # Last pixel: (3,3) -- (x+y)=6 even -> red.
  let lastOff = (3 * W + 3) * 4
  doAssert img.pixels[lastOff + 0] == 255
  doAssert img.pixels[lastOff + 1] == 0
  doAssert img.pixels[lastOff + 2] == 0
  doAssert img.pixels[lastOff + 3] == 255

  # Image registers a placement at the cursor; cell (0,0) maps back.
  let ref0 = s.imageAt(0, 0)
  doAssert ref0.isSome
  doAssert ref0.get == imgs[0]

block kitty_f24_rgb_through_apc:
  ## f=24 is raw RGB; decoder should expand to RGBA with alpha=255.
  var raw = newSeq[byte](2 * 2 * 3)
  raw[0] = 255; raw[1] = 0;   raw[2] = 0    # red
  raw[3] = 0;   raw[4] = 255; raw[5] = 0    # green
  raw[6] = 0;   raw[7] = 0;   raw[8] = 255  # blue
  raw[9] = 255; raw[10] = 255; raw[11] = 255  # white
  var asStr = newString(raw.len)
  for i in 0 ..< raw.len: asStr[i] = char(raw[i])
  let b64 = base64.encode(asStr)
  let payload = "\x1b_Ga=T,f=24,s=2,v=2,i=2;" & b64 & "\x1b\\"

  var s = newScreen(10, 40)
  s.feed(payload)
  let imgs = s.images()
  doAssert imgs.len == 1
  let img = s.imageData(imgs[0])
  doAssert img.format == ifKitty
  doAssert img.width == 2
  doAssert img.height == 2
  doAssert img.pixels.len == 16
  doAssert img.pixels[0] == 255 and img.pixels[1] == 0 and
           img.pixels[2] == 0 and img.pixels[3] == 255
  # Last (white).
  doAssert img.pixels[12] == 255 and img.pixels[13] == 255 and
           img.pixels[14] == 255 and img.pixels[15] == 255

echo "test_apc_kitty_ingest OK"
