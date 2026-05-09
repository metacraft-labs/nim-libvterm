## test_iterm2_png_decode.nim -- end-to-end OSC-1337+PNG ingestion test
## for the iTerm2 inline-image protocol.
##
## Builds a real PNG, base64-encodes it, wraps it in the iTerm2
## `\x1b]1337;File=...:<b64>\x1b\\` envelope, feeds it to a Screen, and
## asserts the registered Image carries decoded RGBA pixels.

import std/base64
import nim_libvterm
import nim_libvterm/decoders/iterm2 as iterm2dec
import ./test_helpers

block iterm2_png_through_osc1337:
  # 5x4 RGB image with an obvious diagonal.
  const W = 5
  const H = 4
  var pixels = newSeq[byte](W * H * 3)
  for y in 0 ..< H:
    for x in 0 ..< W:
      let o = (y * W + x) * 3
      if x == y:
        pixels[o + 0] = 255   # red diagonal
      elif x + y == W - 1:
        pixels[o + 1] = 255   # green anti-diagonal
      else:
        pixels[o + 2] = 255   # blue background

  let pngBytes = encodePng(W, H, 2, pixels)
  var pngStr = newString(pngBytes.len)
  for i in 0 ..< pngBytes.len: pngStr[i] = char(pngBytes[i])
  let b64 = base64.encode(pngStr)
  let payload = "\x1b]1337;File=name=test.png;inline=1:" & b64 & "\x1b\\"

  var s = newScreen(10, 40)
  doAssert s.images().len == 0
  s.feed(payload)
  let imgs = s.images()
  doAssert imgs.len == 1, "got " & $imgs.len
  let img = s.imageData(imgs[0])
  doAssert img.format == ifITerm2
  doAssert img.width == W
  doAssert img.height == H
  doAssert img.pixels.len == W * H * 4

  # Spot-check pixels: (0,0) is red diagonal -> red, (4,0) is anti-diag
  # -> green, (1,0) is background -> blue.
  proc px(x, y: int): array[4, byte] =
    let o = (y * W + x) * 4
    [img.pixels[o], img.pixels[o + 1], img.pixels[o + 2], img.pixels[o + 3]]
  doAssert px(0, 0) == [255'u8, 0, 0, 255]
  doAssert px(4, 0) == [0'u8, 255, 0, 255]
  doAssert px(1, 0) == [0'u8, 0, 255, 255]
  doAssert px(2, 2) == [255'u8, 0, 0, 255]   # diagonal hit

block iterm2_png_direct_decoder:
  ## Same payload through the bare `decodeIterm2` proc (no OSC framing)
  ## -- catches regressions where the OSC pipeline masks a decoder bug.
  const W = 2
  const H = 2
  let pixels = @[
    byte(255), byte(0),   byte(0),   byte(255),
    byte(0),   byte(255), byte(0),   byte(255),
    byte(0),   byte(0),   byte(255), byte(255),
    byte(255), byte(255), byte(0),   byte(255),
  ]
  let pngBytes = encodePng(W, H, 6, pixels)
  var pngStr = newString(pngBytes.len)
  for i in 0 ..< pngBytes.len: pngStr[i] = char(pngBytes[i])
  let payload = "File=name=test.png;inline=1:" & base64.encode(pngStr)
  let img = iterm2dec.decodeIterm2(payload)
  doAssert img.format == ifITerm2
  doAssert img.width == 2
  doAssert img.height == 2
  doAssert img.pixels.len == 16
  for i in 0 ..< 16:
    doAssert img.pixels[i] == pixels[i]

echo "test_iterm2_png_decode OK"
