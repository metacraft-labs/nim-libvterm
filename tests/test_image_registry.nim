## test_image_registry.nim -- image-registry framework.
##
## Pixel decoders (Sixel, Kitty graphics, iTerm2) are deferred -- see
## the milestone status. The framework still records image-escape
## sightings via OSC 1337 so consumers compile against the API.

import nim_libvterm

block:
  var s = newScreen(5, 40)
  doAssert s.images().len == 0

  # iTerm2 OSC 1337 inline image (placeholder data; we only register).
  s.feed("\x1b]1337;File=name=foo.png;inline=1:AAAA\x07")
  let imgs = s.images()
  doAssert imgs.len == 1, "expected one image, got " & $imgs.len

  let data = s.imageData(imgs[0])
  doAssert data.format == ifITerm2, "format=" & $data.format
  # Pixels are not decoded yet (decoders deferred).
  doAssert data.pixels.len == 0

  echo "test_image_registry OK"
