## test_apc_kitty_png_defer.nim -- end-to-end APC ingestion test for the
## `f=100` (PNG) Kitty graphics path.
##
## A real PNG decoder needs zlib + CRC32, which are deferred at L2. The
## ingestion path must NOT crash when handed a PNG-format payload --
## instead it must register a placeholder image with `format = ifKitty`
## and width/height metadata preserved, with `pixels` empty so callers
## can detect the deferred-decode case via `pixels.len == 0`.

import std/base64
import nim_libvterm

block kitty_png_deferred_through_apc:
  # PNG magic bytes (8) + a stub IHDR length so we have something to
  # base64-encode. The decoder never inspects the bytes for f=100; it
  # just raises `KittyDecodeDefer`.
  let pngBytes = [0x89'u8, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
                  0x00, 0x00, 0x00, 0x0D]
  var asStr = newString(pngBytes.len)
  for i in 0 ..< pngBytes.len: asStr[i] = char(pngBytes[i])
  let b64 = base64.encode(asStr)
  let payload = "\x1b_Ga=T,f=100,s=10,v=5,i=42;" & b64 & "\x1b\\"

  var s = newScreen(10, 40)
  doAssert s.images().len == 0

  # The critical assertion: this must not crash. The defer is caught
  # inside `dispatchKittyGraphics` and a placeholder image is registered.
  s.feed(payload)

  let imgs = s.images()
  doAssert imgs.len == 1, "expected one placeholder image, got " & $imgs.len

  let img = s.imageData(imgs[0])
  # Format is ifKitty (not ifPlaceholder) -- the protocol IS Kitty
  # graphics; the *inner* format (PNG) is the deferred bit.
  doAssert img.format == ifKitty, "format=" & $img.format
  # Pixel dimensions preserved from the s= / v= header so consumers can
  # still allocate the right footprint.
  doAssert img.width == 10
  doAssert img.height == 5
  # Pixels NOT decoded -- callers detect deferred decode via empty seq.
  doAssert img.pixels.len == 0,
    "pixels.len should be 0 for deferred PNG decode, got " &
    $img.pixels.len
  # rawSize records the raw payload length for telemetry.
  doAssert img.rawSize > 0

echo "test_apc_kitty_png_defer OK"
