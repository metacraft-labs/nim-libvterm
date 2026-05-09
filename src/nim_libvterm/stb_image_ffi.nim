## stb_image_ffi.nim -- thin FFI to Sean Barrett's `stb_image.h`.
##
## Scope: enough of stb_image to decode in-memory image buffers
## (PNG / JPEG / GIF / BMP / TGA / PSD) into 8-bit RGBA pixels. We
## deliberately ignore the FILE-based entry points (`stbi_load`,
## `stbi_load_from_file`); terminal-image protocols always hand us an
## in-memory base64-decoded buffer, never a path.
##
## Build strategy
## --------------
## stb_image is a single-header library. We vendor the canonical
## upstream copy at `src/nim_libvterm/c/stb_image.h` and expand its
## implementation in exactly one translation unit
## (`src/nim_libvterm/c/stb_image_impl.c`). The `{.compile.}` pragma
## below pulls that .c into every Nim binary that imports this module.
##
## Public surface
## --------------
## * =stbiLoadFromMemory(buf, desiredChannels): StbImage= -- decodes a
##   buffer; returns width / height / actual-channels and the raw pixel
##   bytes as a `seq[byte]`. On failure the returned `pixels` is empty
##   and `failureReason` carries stb_image's error string.
##
## Public-API rules
## ----------------
## * Values only -- `StbImage` is a value `object`; no `ref` escapes.
## * No `cast` outside the FFI boundary; the one `cast[ptr uint8]` to
##   reinterpret the input bytes is justified inline (stb_image's
##   `stbi_load_from_memory` takes `const stbi_uc*` which is `unsigned
##   char*` and is read-only for the duration of the call).
## * stb_image's own `malloc`-backed buffer is freed via
##   `stbi_image_free` immediately after we copy the bytes into a Nim
##   `seq[byte]`, so no foreign-allocator pointers escape this module.

import std/os

const
  cRoot = currentSourcePath().parentDir() & "/c"

{.passc: "-I" & cRoot.}
{.compile: cRoot & "/stb_image_impl.c".}

type
  StbImage* = object
    ## Result of a successful decode. On failure `pixels` is empty and
    ## `width`/`height`/`channels` are zero; check `pixels.len == 0` (or
    ## inspect `stbiFailureReason`) to detect failure.
    width*: int
    height*: int
    channels*: int        ## Channels actually present in the source
                          ## (1=grey, 2=grey+alpha, 3=RGB, 4=RGBA).
    pixels*: seq[byte]    ## Decoded pixels; layout is row-major, byte-
                          ## interleaved. Length =
                          ## width * height * desiredChannels.

# stb_image's C entry points. `stbi_uc` is `unsigned char`; we mirror it
# as `uint8` so the pointer arithmetic is well-typed on every platform.
proc stbiLoadFromMemoryRaw(buffer: ptr uint8; len: cint;
                           x, y, channelsInFile: ptr cint;
                           desiredChannels: cint): ptr uint8
  {.importc: "stbi_load_from_memory", header: "stb_image.h".}

proc stbiImageFree(retval: ptr uint8)
  {.importc: "stbi_image_free", header: "stb_image.h".}

proc stbiFailureReasonRaw(): cstring
  {.importc: "stbi_failure_reason", header: "stb_image.h".}

proc stbiFailureReason*(): string =
  ## Last decode failure reason as reported by stb_image. Empty string
  ## if stb_image hasn't recorded one. The string is owned by
  ## stb_image's static storage; we copy it into a Nim string before
  ## returning so callers don't have to worry about lifetimes.
  let raw = stbiFailureReasonRaw()
  if raw.isNil: "" else: $raw

proc stbiLoadFromMemory*(buffer: openArray[byte];
                         desiredChannels: int = 4): StbImage =
  ## Decode an in-memory image buffer (PNG / JPEG / GIF / BMP / TGA /
  ## PSD; format auto-detected by stb_image from magic bytes).
  ##
  ## `desiredChannels` requests a channel count in the OUTPUT pixels:
  ##   * 1 = greyscale
  ##   * 2 = grey + alpha
  ##   * 3 = RGB
  ##   * 4 = RGBA  (the default; what every terminal image consumer wants)
  ##
  ## On failure returns a zero-initialised `StbImage` with empty
  ## `pixels`; callers can read `stbiFailureReason()` for the reason.
  if buffer.len <= 0:
    return  # zero-initialised StbImage
  var w, h, c: cint
  # `unsafeAddr buffer[0]` -- buffer is `openArray[byte]`, cast to the
  # `unsigned char*` stb_image expects. stb_image treats this pointer as
  # read-only for the duration of the call (declared `stbi_uc const*`),
  # so the cast is sound. This is the FFI boundary justification for the
  # single `cast[ptr uint8]` site in this module.
  let raw = stbiLoadFromMemoryRaw(
    cast[ptr uint8](unsafeAddr buffer[0]),
    cint(buffer.len),
    addr w, addr h, addr c,
    cint(desiredChannels))
  if raw.isNil:
    return  # zero-initialised StbImage; caller checks pixels.len == 0
  let outChannels = if desiredChannels == 0: int(c) else: desiredChannels
  let total = int(w) * int(h) * outChannels
  result.width = int(w)
  result.height = int(h)
  result.channels = int(c)
  result.pixels = newSeq[byte](total)
  if total > 0:
    copyMem(addr result.pixels[0], raw, total)
  stbiImageFree(raw)
