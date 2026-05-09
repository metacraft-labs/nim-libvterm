## test_apc_kitty_png_defer.nim -- end-to-end APC ingestion test for the
## `f=100` (PNG) Kitty graphics path.
##
## Originally this test asserted that PNG payloads registered an empty-
## pixels placeholder (the PNG decoder was deferred). With the pure-Nim
## PNG decoder shipped, the same payload now produces a real, populated
## Image -- this test guards that progression.
##
## We still feed a real PNG (built via `encodePng`) so the assertion
## chain is end-to-end: APC parse -> base64 decode -> PNG decode ->
## image registry.

import std/base64
import nim_libvterm
import ./test_helpers

const W = 10
const H = 5

block kitty_png_decoded_through_apc:
  # A 10x5 RGBA pattern: every pixel solid red, full alpha.
  var raw = newSeq[byte](W * H * 4)
  for i in 0 ..< W * H:
    raw[i * 4 + 0] = 255
    raw[i * 4 + 1] = 0
    raw[i * 4 + 2] = 0
    raw[i * 4 + 3] = 255
  let pngBytes = encodePng(W, H, 6, raw)
  var pngStr = newString(pngBytes.len)
  for i in 0 ..< pngBytes.len: pngStr[i] = char(pngBytes[i])
  let b64 = base64.encode(pngStr)
  let payload = "\x1b_Ga=T,f=100,s=10,v=5,i=42;" & b64 & "\x1b\\"

  var s = newScreen(10, 40)
  doAssert s.images().len == 0

  s.feed(payload)

  let imgs = s.images()
  doAssert imgs.len == 1, "expected one image, got " & $imgs.len

  let img = s.imageData(imgs[0])
  # Format is ifKitty -- the protocol IS Kitty graphics.
  doAssert img.format == ifKitty, "format=" & $img.format
  # PNG IHDR is the source of truth for dimensions; the s=/v= values
  # match here so we assert the same numbers.
  doAssert img.width == W, "width=" & $img.width
  doAssert img.height == H, "height=" & $img.height
  # PNG decoder ran -- pixels are populated.
  doAssert img.pixels.len == W * H * 4,
    "expected " & $(W * H * 4) & " RGBA bytes, got " & $img.pixels.len
  # Spot-check the colour we encoded.
  doAssert img.pixels[0] == 255
  doAssert img.pixels[1] == 0
  doAssert img.pixels[2] == 0
  doAssert img.pixels[3] == 255
  let lastOff = (W * H - 1) * 4
  doAssert img.pixels[lastOff + 0] == 255
  doAssert img.pixels[lastOff + 1] == 0
  doAssert img.pixels[lastOff + 2] == 0
  doAssert img.pixels[lastOff + 3] == 255
  # rawSize records the raw payload length for telemetry.
  doAssert img.rawSize > 0

echo "test_apc_kitty_png_defer OK"
