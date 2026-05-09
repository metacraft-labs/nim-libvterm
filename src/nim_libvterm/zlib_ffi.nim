## zlib_ffi.nim -- thin FFI to the system zlib for the PNG decoder.
##
## Scope: just enough of zlib to inflate PNG IDAT streams and to compute
## CRC32 over chunk type+payload. No deflate (we never write PNGs in
## production); no checksums beyond CRC32; no gzip framing.
##
## We bind to the system =libz= (available in the nix devShell). The
## struct layout below mirrors =z_stream= from =<zlib.h>= and uses
## =importc= so the C compiler picks up field offsets from the header --
## we do not hand-compute layouts.
##
## Public surface:
##   * =inflateBytes(src: openArray[byte]): seq[byte]= -- one-shot
##     decompression of a complete zlib stream (which is exactly what an
##     IDAT-concatenation produces). Streaming-friendly internally so
##     output > input is fine.
##   * =crc32Bytes(data: openArray[byte]): uint32= -- IEEE CRC32 of a
##     buffer using zlib's table-driven implementation.
##   * =crc32Update(seed: uint32; data: openArray[byte]): uint32= -- for
##     incremental CRC over (chunk-type bytes ++ chunk-data bytes).

{.passl: "-lz".}

type
  ZStream* {.importc: "z_stream", header: "<zlib.h>", bycopy.} = object
    next_in: ptr uint8
    avail_in: cuint
    total_in: culong
    next_out: ptr uint8
    avail_out: cuint
    total_out: culong
    msg: cstring
    state: pointer
    zalloc: pointer
    zfree: pointer
    opaque: pointer
    data_type: cint
    adler: culong
    reserved: culong

  ZlibError* = object of CatchableError

proc inflateInit2(strm: ptr ZStream; windowBits: cint;
                  version: cstring; size: cint): cint
  {.importc: "inflateInit2_", header: "<zlib.h>".}

proc inflate(strm: ptr ZStream; flush: cint): cint
  {.importc, header: "<zlib.h>".}

proc inflateEnd(strm: ptr ZStream): cint
  {.importc, header: "<zlib.h>".}

proc deflateInitImpl(strm: ptr ZStream; level: cint;
                     version: cstring; size: cint): cint
  {.importc: "deflateInit_", header: "<zlib.h>".}

proc deflate(strm: ptr ZStream; flush: cint): cint
  {.importc, header: "<zlib.h>".}

proc deflateEnd(strm: ptr ZStream): cint
  {.importc, header: "<zlib.h>".}

proc compressBound(sourceLen: culong): culong
  {.importc: "compressBound", header: "<zlib.h>".}

proc zlibVersion(): cstring
  {.importc: "zlibVersion", header: "<zlib.h>".}

proc crc32Raw(crc: culong; buf: ptr uint8; len: cuint): culong
  {.importc: "crc32", header: "<zlib.h>".}

const
  Z_OK* = 0.cint
  Z_STREAM_END* = 1.cint
  Z_NO_FLUSH* = 0.cint
  Z_FINISH* = 4.cint
  Z_DEFAULT_COMPRESSION* = -1.cint

proc inflateBytes*(src: openArray[byte]): seq[byte] =
  ## One-shot inflate of a complete zlib-wrapped stream.
  ##
  ## Uses a streaming inflate loop with a growing output buffer so
  ## payloads of unknown decompressed size (the PNG IDAT case) work
  ## without a precomputed length.
  if src.len == 0:
    return @[]
  var strm: ZStream
  let initRc = inflateInit2(addr strm, 15.cint,
                            zlibVersion(), cint(sizeof(ZStream)))
  if initRc != Z_OK:
    raise newException(ZlibError,
      "zlib: inflateInit2 returned " & $initRc)

  # Pin the input. We treat `src` as immutable for the duration of the
  # call. zlib does not mutate `next_in`/the buffer it points at.
  strm.next_in = cast[ptr uint8](unsafeAddr src[0])
  strm.avail_in = cuint(src.len)

  # Start with a guess that PNG IDAT typically expands ~4-8x. Grow on
  # demand. We avoid culong arithmetic in the public seq size.
  var outBuf = newSeq[byte](max(4096, src.len * 4))
  var produced = 0

  while true:
    if produced == outBuf.len:
      # Need more room. Double the buffer.
      outBuf.setLen(outBuf.len * 2)
    strm.next_out = cast[ptr uint8](addr outBuf[produced])
    strm.avail_out = cuint(outBuf.len - produced)
    let beforeOut = strm.avail_out
    let rc = inflate(addr strm, Z_NO_FLUSH)
    let consumed = beforeOut - strm.avail_out
    produced += int(consumed)
    if rc == Z_STREAM_END:
      break
    if rc != Z_OK:
      let msg = if strm.msg.isNil: "unknown" else: $strm.msg
      discard inflateEnd(addr strm)
      raise newException(ZlibError,
        "zlib: inflate returned " & $rc & " (" & msg & ")")
    # rc == Z_OK but no progress + no input left => stream truncated.
    if consumed == 0 and strm.avail_in == 0:
      discard inflateEnd(addr strm)
      raise newException(ZlibError,
        "zlib: input exhausted before stream end")

  discard inflateEnd(addr strm)
  outBuf.setLen(produced)
  result = outBuf

proc crc32Update*(seed: uint32; data: openArray[byte]): uint32 =
  ## Update an existing CRC32 with more bytes. Use seed=0 for a fresh
  ## CRC. The PNG spec requires CRC over chunk-type ++ chunk-data, so
  ## this is the building block.
  if data.len == 0:
    return seed
  let r = crc32Raw(culong(seed),
                   cast[ptr uint8](unsafeAddr data[0]),
                   cuint(data.len))
  uint32(r and 0xFFFFFFFF.culong)

proc crc32Bytes*(data: openArray[byte]): uint32 =
  ## CRC32 of a single buffer (seed=0).
  crc32Update(0'u32, data)

proc deflateBytes*(src: openArray[byte];
                   level: cint = Z_DEFAULT_COMPRESSION): seq[byte] =
  ## One-shot deflate of a buffer to a complete zlib-wrapped stream.
  ## Used by tests to build the IDAT payload of a hand-rolled PNG.
  if src.len == 0:
    # Even an empty input still needs a valid zlib wrapper. Round-trip
    # via the streaming API so we don't have to know the exact bytes.
    discard
  var strm: ZStream
  let initRc = deflateInitImpl(addr strm, level,
                               zlibVersion(), cint(sizeof(ZStream)))
  if initRc != Z_OK:
    raise newException(ZlibError,
      "zlib: deflateInit returned " & $initRc)

  if src.len > 0:
    strm.next_in = cast[ptr uint8](unsafeAddr src[0])
  strm.avail_in = cuint(src.len)

  let upper = int(compressBound(culong(src.len)))
  var outBuf = newSeq[byte](upper)
  strm.next_out = cast[ptr uint8](addr outBuf[0])
  strm.avail_out = cuint(upper)

  let rc = deflate(addr strm, Z_FINISH)
  if rc != Z_STREAM_END:
    let msg = if strm.msg.isNil: "unknown" else: $strm.msg
    discard deflateEnd(addr strm)
    raise newException(ZlibError,
      "zlib: deflate(Z_FINISH) returned " & $rc & " (" & msg & ")")
  let produced = upper - int(strm.avail_out)
  discard deflateEnd(addr strm)
  outBuf.setLen(produced)
  result = outBuf
