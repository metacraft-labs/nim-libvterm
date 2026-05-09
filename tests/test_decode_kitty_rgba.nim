## test_decode_kitty_rgba.nim -- exact-byte test for the Kitty graphics
## raw RGBA decoder.
##
## Fixture: a 4×4 image with a known checkerboard pattern. We build the
## RGBA bytes inline, base64-encode them, hand the base64 string to
## `decodeKittyRgba(payload, format=32, width=4, height=4)`, and assert
## width/height/first/middle/last RGBA + the FNV-1a hash of the full
## buffer.

import std/base64
import nim_libvterm/decoders/kitty

const W = 4
const H = 4

# ---------------------------------------------------------------------------
# Compose the source bytes -- RGBA, row-major, 4 bytes per pixel.
# Pattern: checkerboard of red (255,0,0,255) and green (0,255,0,255).
# ---------------------------------------------------------------------------
proc fnv1a(b: openArray[byte]): uint64 =
  result = 0xcbf29ce484222325'u64
  for x in b:
    result = result xor uint64(x)
    result = result * 0x100000001b3'u64

proc buildRgba(): seq[byte] =
  result = newSeq[byte](W * H * 4)
  for y in 0 ..< H:
    for x in 0 ..< W:
      let p = (y * W + x) * 4
      if ((x + y) and 1) == 0:
        # red
        result[p + 0] = 255
        result[p + 1] = 0
        result[p + 2] = 0
        result[p + 3] = 255
      else:
        # green
        result[p + 0] = 0
        result[p + 1] = 255
        result[p + 2] = 0
        result[p + 3] = 255

block raw_rgba_f32:
  let raw = buildRgba()
  var asString = newString(raw.len)
  for i in 0 ..< raw.len:
    asString[i] = char(raw[i])
  let b64 = base64.encode(asString)

  let img = decodeKittyRgba(b64, format = 32, width = W, height = H)
  doAssert img.format == ifKitty
  doAssert img.width == W
  doAssert img.height == H
  doAssert img.pixels.len == W * H * 4

  # First pixel: (0,0) -- red.
  doAssert img.pixels[0] == 255
  doAssert img.pixels[1] == 0
  doAssert img.pixels[2] == 0
  doAssert img.pixels[3] == 255

  # Middle pixel: (2,2) -- (x+y)=4 even -> red.
  let midOff = (2 * W + 2) * 4
  doAssert img.pixels[midOff + 0] == 255
  doAssert img.pixels[midOff + 1] == 0
  doAssert img.pixels[midOff + 2] == 0
  doAssert img.pixels[midOff + 3] == 255

  # Last pixel: (3,3) -- (x+y)=6 even -> red.
  let lastOff = (3 * W + 3) * 4
  doAssert img.pixels[lastOff + 0] == 255
  doAssert img.pixels[lastOff + 1] == 0
  doAssert img.pixels[lastOff + 2] == 0
  doAssert img.pixels[lastOff + 3] == 255

  # Hash check.
  let h = fnv1a(img.pixels)
  # Pre-computed for the 4x4 red/green checkerboard above.
  doAssert h == 0xbdca7f83b1f2e355'u64,
    "kitty hash mismatch: " & $h

block raw_rgb_f24:
  # Build 2x2 RGB-only -- (255,0,0), (0,255,0), (0,0,255), (255,255,255)
  var raw = newSeq[byte](2 * 2 * 3)
  raw[0] = 255; raw[1] = 0; raw[2] = 0
  raw[3] = 0;   raw[4] = 255; raw[5] = 0
  raw[6] = 0;   raw[7] = 0;   raw[8] = 255
  raw[9] = 255; raw[10] = 255; raw[11] = 255
  var s = newString(raw.len)
  for i in 0 ..< raw.len: s[i] = char(raw[i])
  let b64 = base64.encode(s)

  let img = decodeKittyRgba(b64, format = 24, width = 2, height = 2)
  doAssert img.format == ifKitty
  doAssert img.width == 2
  doAssert img.height == 2
  doAssert img.pixels.len == 16
  doAssert img.pixels[0] == 255 and img.pixels[1] == 0 and
           img.pixels[2] == 0 and img.pixels[3] == 255
  # Last (white) -> (255,255,255,255)
  doAssert img.pixels[12] == 255 and img.pixels[13] == 255 and
           img.pixels[14] == 255 and img.pixels[15] == 255

block deferred_png:
  var raised = false
  try:
    discard decodeKittyRgba("AAAA", format = 100, width = 1, height = 1)
  except KittyDecodeDefer:
    raised = true
  doAssert raised, "expected KittyDecodeDefer for f=100"

echo "test_decode_kitty_rgba OK"
