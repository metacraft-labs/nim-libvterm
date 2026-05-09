## decoders/kitty.nim -- Kitty graphics protocol pixel decoder.
##
## The Kitty graphics protocol transmits image data via APC sequences with a
## key/value control header followed by an opaque payload. The relevant
## format selectors:
##
##   * f=24  -- raw 24-bit RGB, base64-encoded
##   * f=32  -- raw 32-bit RGBA, base64-encoded (default)
##   * f=100 -- PNG bytes, base64-encoded (deferred -- needs zlib+CRC)
##
## We decode the raw forms here (they are what test fixtures use and what
## TUI authors with "no PNG, just blit pixels" workflows tend to ship).
## PNG support raises a `KittyDecodeDefer` -- callers can detect this and
## either fall back or surface the error to the user.
##
## Public-API rules: this module returns a value `Image` with `pixels`
## populated as RGBA row-major (4 bytes/pixel). It does NOT touch the
## extended-state overlay.

import std/base64
import ../image_types
export image_types

type
  KittyDecodeError* = object of CatchableError
  KittyDecodeDefer* = object of CatchableError
    ## Raised for `f=100` (PNG) -- a real PNG decoder needs zlib + CRC32
    ## which exceed the stdlib budget. Callers can catch this and either
    ## fall back to an empty `Image` or attempt to decode externally.

proc decodeKittyRgba*(payload: string; format: int;
                      width, height: int): Image =
  ## Decode a base64-encoded raw Kitty graphics payload.
  ##
  ## `format` is the Kitty `f=` parameter (24 or 32).
  ## `width`/`height` are the pixel dimensions as transmitted via the
  ## `s=` and `v=` parameters of the Kitty header.
  ##
  ## Returns an `Image` with `format = ifKitty` and `pixels` populated
  ## RGBA row-major. Raises `KittyDecodeDefer` for `f=100` (PNG) and
  ## `KittyDecodeError` for malformed input or unsupported formats.
  if format == 100:
    raise newException(KittyDecodeDefer,
      "Kitty f=100 (PNG) decoding requires zlib+CRC32 -- deferred")
  if format != 24 and format != 32:
    raise newException(KittyDecodeError,
      "Kitty graphics: unsupported format f=" & $format)
  if width <= 0 or height <= 0:
    raise newException(KittyDecodeError,
      "Kitty graphics: invalid dimensions " & $width & "x" & $height)

  let raw = base64.decode(payload)
  let bytesPerPixel = if format == 32: 4 else: 3
  let expected = width * height * bytesPerPixel
  if raw.len < expected:
    raise newException(KittyDecodeError,
      "Kitty graphics: payload too short -- got " & $raw.len &
      " bytes, expected " & $expected)

  result.format = ifKitty
  result.width = width
  result.height = height
  result.rawSize = payload.len

  if format == 32:
    # f=32 is already RGBA; just copy the pixel section.
    result.pixels = newSeq[byte](expected)
    for i in 0 ..< expected:
      result.pixels[i] = byte(raw[i])
  else:
    # f=24 -- expand RGB to RGBA with alpha = 255.
    let total = width * height
    result.pixels = newSeq[byte](total * 4)
    var src = 0
    var dst = 0
    while src + 3 <= raw.len and dst + 4 <= result.pixels.len:
      result.pixels[dst + 0] = byte(raw[src + 0])
      result.pixels[dst + 1] = byte(raw[src + 1])
      result.pixels[dst + 2] = byte(raw[src + 2])
      result.pixels[dst + 3] = 0xFF
      src += 3
      dst += 4
