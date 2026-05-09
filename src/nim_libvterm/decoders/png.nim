## decoders/png.nim -- thin wrapper around stb_image for PNG (and other
## stb_image-supported formats) used by the Kitty `f=100` and iTerm2
## inline-image paths.
##
## Historical note: an earlier revision of this module shipped a
## hand-rolled pure-Nim PNG decoder (~350 LOC plus a zlib FFI). It was
## replaced by `stb_image` -- a single-header library that handles the
## same set of color types AND adds Adam7 interlacing, 16-bit depth,
## greyscale variants, plus JPEG / GIF / BMP / TGA / PSD for free.
##
## Supported (delegated to stb_image)
## ----------------------------------
##  * PNG: all color types (greyscale, RGB, palette, greyscale+alpha,
##    RGBA), 8 and 16 bits per channel, Adam7 interlacing.
##  * Multiple IDAT chunks; tRNS; gAMA / iCCP / sRGB / tEXt etc. handled
##    by stb_image's chunk walker (we don't act on colour-management
##    metadata; the decoded pixels are sRGB by convention).
##
## Public-API rules: returns a value =Image=. No `ref`. No `cast` in the
## public API. Errors are =PngDecodeError= -- a single exception type so
## callers can wrap with one =except=.

import ../image_types
import ../stb_image_ffi
export image_types

type
  PngDecodeError* = object of CatchableError

proc decodePng*(payload: openArray[byte]): Image =
  ## Decode a PNG (or any stb_image-supported format) byte buffer to an
  ## RGBA Image. We force `desiredChannels = 4` so the output is always
  ## RGBA regardless of source colour type; stb_image expands greyscale
  ## and RGB to RGBA with alpha=255 and decodes palette-indexed PNGs.
  ##
  ## Raises =PngDecodeError= on:
  ##   * Empty input.
  ##   * Bytes that stb_image cannot decode (bad signature, truncated
  ##     stream, CRC failure inside zlib, malformed chunks, etc.).
  if payload.len == 0:
    raise newException(PngDecodeError, "png: empty payload")
  let decoded = stbiLoadFromMemory(payload, desiredChannels = 4)
  if decoded.pixels.len == 0:
    raise newException(PngDecodeError,
      "png: stb_image failed: " & stbiFailureReason())
  result.format = ifPlaceholder  # caller (Kitty / iTerm2) overwrites
  result.width = decoded.width
  result.height = decoded.height
  result.rawSize = payload.len
  result.pixels = decoded.pixels
