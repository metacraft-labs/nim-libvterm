## decoders/iterm2.nim -- iTerm2 OSC 1337 inline-image decoder.
##
## Format (post-OSC-1337-and-`File=`-prefix):
##
##   File=<key>=<value>;<key>=<value>;...:<base64-image-bytes>
##
## The trailing payload is base64-encoded bytes of an image. The iTerm2
## protocol deliberately does not restrict the inner format -- "PNG, GIF,
## JPEG, or other format". With stb_image as the backend we now decode
## PNG, JPEG, GIF, BMP, TGA and PSD; the format is auto-detected from
## magic bytes by stb_image. We retain `IItermDecodeError` (malformed
## envelope or stb_image rejection) and `IItermDecodeDefer` (genuinely
## unsupported inner format -- never raised by stb_image's code path
## today, kept for API compatibility).

import std/[base64, strutils]
import ../image_types
import ../stb_image_ffi
export image_types

type
  IItermDecodeError* = object of CatchableError
  IItermDecodeDefer* = object of CatchableError
    ## Historically raised for PNG / JPEG / GIF inner formats that the
    ## hand-rolled BMP-only decoder did not handle. With stb_image those
    ## formats decode inline, so this exception is no longer raised by
    ## `decodeIterm2`. Retained in the public API so callers that still
    ## `except IItermDecodeDefer` keep compiling.

# ---------------------------------------------------------------------------
# Public entry point
# ---------------------------------------------------------------------------

proc decodeIterm2*(payload: string): Image =
  ## Decode an iTerm2 OSC 1337 payload. The input is the OSC body AFTER
  ## the `1337;` command code and BEFORE the terminator -- i.e. a string
  ## that begins with `File=...:<base64>` (or another iTerm2 command,
  ## which we reject).
  ##
  ## Raises `IItermDecodeError` for malformed input or any payload that
  ## stb_image cannot decode.
  if not payload.startsWith("File="):
    raise newException(IItermDecodeError,
      "iTerm2: payload does not begin with 'File='")
  let colon = payload.find(':')
  if colon < 0:
    raise newException(IItermDecodeError,
      "iTerm2: missing ':' between metadata and base64 body")
  let b64 = payload[colon + 1 .. ^1]
  let raw = base64.decode(b64)
  if raw.len == 0:
    raise newException(IItermDecodeError, "iTerm2: empty image bytes")

  # Hand the bytes straight to stb_image; format is sniffed from magic.
  var rawBytes = newSeq[byte](raw.len)
  for i in 0 ..< raw.len: rawBytes[i] = byte(raw[i])
  let decoded = stbiLoadFromMemory(rawBytes, desiredChannels = 4)
  if decoded.pixels.len == 0:
    let leadHex =
      if raw.len >= 4:
        $byte(raw[0]) & " " & $byte(raw[1]) & " " &
        $byte(raw[2]) & " " & $byte(raw[3])
      else:
        "<short>"
    raise newException(IItermDecodeError,
      "iTerm2: stb_image rejected inner image (first bytes: " & leadHex &
      "; reason: " & stbiFailureReason() & ")")
  result.format = ifITerm2
  result.width = decoded.width
  result.height = decoded.height
  result.rawSize = raw.len
  result.pixels = decoded.pixels
