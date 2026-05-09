## decoders/kitty.nim -- Kitty graphics protocol pixel decoder.
##
## The Kitty graphics protocol transmits image data via APC sequences with a
## key/value control header followed by an opaque payload. The relevant
## format selectors:
##
##   * f=24  -- raw 24-bit RGB, base64-encoded
##   * f=32  -- raw 32-bit RGBA, base64-encoded (default)
##   * f=100 -- PNG bytes, base64-encoded
##
## We decode all three. `f=100` dispatches to the stb_image-backed PNG
## decoder in `decoders/png.nim`. PNG carries its own width/height in
## IHDR, which is the source of truth: when the Kitty `s=`/`v=` header
## parameters disagree with IHDR (or are zero/unset, as is common when
## the sender relies on the PNG header) we trust IHDR.
## `KittyDecodeDefer` remains in the public API for backward
## compatibility but is no longer raised by `decodeKittyRgba` -- with
## stb_image every PNG that decodes is fully expanded to RGBA inline.
##
## Public-API rules: this module returns a value `Image` with `pixels`
## populated as RGBA row-major (4 bytes/pixel). It does NOT touch the
## extended-state overlay.

import std/base64
import ../image_types
import ./png as pngdec
export image_types

type
  KittyDecodeError* = object of CatchableError
  KittyDecodeDefer* = object of CatchableError
    ## Historically raised for `f=100` (PNG). Retained in the public API
    ## so callers that still `except KittyDecodeDefer` keep compiling --
    ## the new PNG path raises `KittyDecodeError` (wrapping
    ## `PngDecodeError`) on malformed PNGs instead.

proc decodeKittyRgba*(payload: string; format: int;
                      width, height: int): Image =
  ## Decode a base64-encoded raw Kitty graphics payload.
  ##
  ## `format` is the Kitty `f=` parameter (24 or 32).
  ## `width`/`height` are the pixel dimensions as transmitted via the
  ## `s=` and `v=` parameters of the Kitty header.
  ##
  ## Returns an `Image` with `format = ifKitty` and `pixels` populated
  ## RGBA row-major. Raises `KittyDecodeError` for malformed input or
  ## unsupported formats.
  if format == 100:
    # PNG: ignore the s=/v= dimensions -- IHDR is the source of truth.
    # Kitty senders sometimes omit s=/v= entirely for f=100 because the
    # PNG header carries the same information.
    let raw = base64.decode(payload)
    var rawBytes = newSeq[byte](raw.len)
    for i in 0 ..< raw.len: rawBytes[i] = byte(raw[i])
    var img: Image
    try:
      img = pngdec.decodePng(rawBytes)
    except pngdec.PngDecodeError as e:
      raise newException(KittyDecodeError,
        "Kitty f=100 (PNG) decode failed: " & e.msg)
    img.format = ifKitty
    img.rawSize = payload.len
    return img
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
