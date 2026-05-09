## test_iterm2_jpeg_decode.nim -- end-to-end OSC-1337+JPEG ingestion
## test for the iTerm2 inline-image protocol.
##
## With stb_image as the decoder backend, JPEG inner format inside an
## OSC 1337 envelope is now fully decoded (previously the path raised
## `IItermDecodeDefer`). We assert the registered Image carries decoded
## RGBA pixels.

import std/base64
import nim_libvterm
import nim_libvterm/decoders/iterm2 as iterm2dec
import ./fixtures_jpeg_gif

block iterm2_jpeg_through_osc1337:
  var jpegStr = newString(SolidRedJpeg8x8.len)
  for i in 0 ..< SolidRedJpeg8x8.len:
    jpegStr[i] = char(SolidRedJpeg8x8[i])
  let b64 = base64.encode(jpegStr)
  let payload = "\x1b]1337;File=name=test.jpg;inline=1:" & b64 & "\x1b\\"

  var s = newScreen(10, 40)
  doAssert s.images().len == 0
  s.feed(payload)
  let imgs = s.images()
  doAssert imgs.len == 1, "got " & $imgs.len
  let img = s.imageData(imgs[0])
  doAssert img.format == ifITerm2
  doAssert img.width == 8
  doAssert img.height == 8
  doAssert img.pixels.len == 8 * 8 * 4
  # Spot-check: corner pixel is the JPEG-quantised red.
  doAssert img.pixels[0] == 0xFE'u8
  doAssert img.pixels[1] == 0x00'u8
  doAssert img.pixels[2] == 0x00'u8
  doAssert img.pixels[3] == 0xFF'u8

block iterm2_jpeg_direct_decoder:
  ## Same payload through the bare `decodeIterm2` proc.
  var jpegStr = newString(SolidRedJpeg8x8.len)
  for i in 0 ..< SolidRedJpeg8x8.len:
    jpegStr[i] = char(SolidRedJpeg8x8[i])
  let payload = "File=name=test.jpg;inline=1:" & base64.encode(jpegStr)
  let img = iterm2dec.decodeIterm2(payload)
  doAssert img.format == ifITerm2
  doAssert img.width == 8
  doAssert img.height == 8
  doAssert img.pixels.len == 8 * 8 * 4
  for i in 0 ..< 8 * 8:
    let o = i * 4
    doAssert img.pixels[o + 0] == 0xFE'u8
    doAssert img.pixels[o + 1] == 0x00'u8
    doAssert img.pixels[o + 2] == 0x00'u8
    doAssert img.pixels[o + 3] == 0xFF'u8

echo "test_iterm2_jpeg_decode OK"
