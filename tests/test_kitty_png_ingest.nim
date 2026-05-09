## test_kitty_png_ingest.nim -- end-to-end APC+f=100 ingestion test for
## Kitty graphics PNG payloads.
##
## Builds a real 4x4 RGBA PNG, base64-encodes it, wraps it in the Kitty
## APC envelope (`\x1b_Ga=T,f=100,...;<base64-PNG>\x1b\\`), feeds it to
## a Screen, and asserts the registered Image carries the decoded RGBA
## pixels (NOT a placeholder).
##
## This is the milestone-defining test: prior to the PNG decoder landing
## the same payload would register an empty-pixels placeholder.

import std/[base64, options]
import nim_libvterm
import ./test_helpers

const W = 4
const H = 4

proc buildRgba(): seq[byte] =
  ## Same checkerboard as `test_apc_kitty_ingest.nim` so the assertions
  ## look familiar -- but here it's encoded as a PNG, not raw RGBA.
  result = newSeq[byte](W * H * 4)
  for y in 0 ..< H:
    for x in 0 ..< W:
      let p = (y * W + x) * 4
      if ((x + y) and 1) == 0:
        result[p + 0] = 255
        result[p + 1] = 0
        result[p + 2] = 0
        result[p + 3] = 255
      else:
        result[p + 0] = 0
        result[p + 1] = 255
        result[p + 2] = 0
        result[p + 3] = 255

block kitty_f100_through_apc:
  let raw = buildRgba()
  let pngBytes = encodePng(W, H, 6, raw)
  var pngStr = newString(pngBytes.len)
  for i in 0 ..< pngBytes.len: pngStr[i] = char(pngBytes[i])
  let b64 = base64.encode(pngStr)
  let payload = "\x1b_Ga=T,f=100,s=4,v=4,i=7;" & b64 & "\x1b\\"

  var s = newScreen(10, 40)
  doAssert s.images().len == 0
  s.feed(payload)

  let imgs = s.images()
  doAssert imgs.len == 1, "expected one image, got " & $imgs.len

  let img = s.imageData(imgs[0])
  doAssert img.format == ifKitty, "format=" & $img.format
  doAssert img.width == W, "width=" & $img.width
  doAssert img.height == H, "height=" & $img.height
  doAssert img.pixels.len == W * H * 4,
    "pixels.len=" & $img.pixels.len & " expected " & $(W * H * 4)
  for i in 0 ..< raw.len:
    doAssert img.pixels[i] == raw[i],
      "byte " & $i & " mismatch: got " & $img.pixels[i] &
      " expected " & $raw[i]

  # Image registers a placement; cell (0,0) maps back.
  let ref0 = s.imageAt(0, 0)
  doAssert ref0.isSome
  doAssert ref0.get == imgs[0]

block kitty_f100_dimensions_omitted:
  ## A sender that omits s=/v= for f=100 (relying on PNG's IHDR) must
  ## still decode correctly -- the decoder reads dimensions from IHDR.
  let raw = newSeq[byte](2 * 3 * 4)  # 2x3 RGBA, all zeros (transparent)
  let pngBytes = encodePng(2, 3, 6, raw)
  var pngStr = newString(pngBytes.len)
  for i in 0 ..< pngBytes.len: pngStr[i] = char(pngBytes[i])
  let b64 = base64.encode(pngStr)
  let payload = "\x1b_Ga=T,f=100,i=8;" & b64 & "\x1b\\"

  var s = newScreen(10, 40)
  s.feed(payload)
  let imgs = s.images()
  doAssert imgs.len == 1
  let img = s.imageData(imgs[0])
  doAssert img.format == ifKitty
  doAssert img.width == 2
  doAssert img.height == 3
  doAssert img.pixels.len == 24

echo "test_kitty_png_ingest OK"
