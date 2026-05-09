## test_iterm2_gif_decode.nim -- end-to-end OSC-1337+GIF ingestion test
## for the iTerm2 inline-image protocol.
##
## With stb_image as the decoder backend, GIF inner format inside an
## OSC 1337 envelope is now fully decoded (previously the path raised
## `IItermDecodeDefer`). GIF is lossless, so we assert byte-equal RGBA
## output.

import std/base64
import nim_libvterm
import nim_libvterm/decoders/iterm2 as iterm2dec
import ./fixtures_jpeg_gif

block iterm2_gif_through_osc1337:
  var gifStr = newString(Colors2x2Gif.len)
  for i in 0 ..< Colors2x2Gif.len:
    gifStr[i] = char(Colors2x2Gif[i])
  let b64 = base64.encode(gifStr)
  let payload = "\x1b]1337;File=name=test.gif;inline=1:" & b64 & "\x1b\\"

  var s = newScreen(10, 40)
  doAssert s.images().len == 0
  s.feed(payload)
  let imgs = s.images()
  doAssert imgs.len == 1, "got " & $imgs.len
  let img = s.imageData(imgs[0])
  doAssert img.format == ifITerm2
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

block iterm2_gif_direct_decoder:
  var gifStr = newString(Colors2x2Gif.len)
  for i in 0 ..< Colors2x2Gif.len:
    gifStr[i] = char(Colors2x2Gif[i])
  let payload = "File=name=test.gif;inline=1:" & base64.encode(gifStr)
  let img = iterm2dec.decodeIterm2(payload)
  doAssert img.format == ifITerm2
  doAssert img.width == 2
  doAssert img.height == 2
  doAssert img.pixels.len == 16
  doAssert img.pixels[0] == 0xFF'u8
  doAssert img.pixels[15] == 0xFF'u8  # last alpha byte

echo "test_iterm2_gif_decode OK"
