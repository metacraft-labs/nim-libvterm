## test_decode_png_invalid.nim -- malformed-input rejection tests for
## the stb_image-backed PNG decoder.
##
## Each `block` constructs a deliberately broken PNG (or non-PNG) and
## asserts that `decodePng` raises `PngDecodeError` with a usable
## message. With stb_image as the backend, several inputs that the
## previous hand-rolled decoder rejected (Adam7 interlacing, greyscale
## colour types, 16-bit-per-channel) now SUCCEED -- the corresponding
## blocks have been retired. Conversely, some inputs that the previous
## decoder rejected (CRC mismatch, missing IEND chunk, ancillary-chunk
## quirks) are tolerated by stb_image, which is permissive about
## chunk-level validity. We retain only the inputs that ANY conformant
## image decoder must reject: empty, signature-not-anything, truncated
## headers.

import nim_libvterm/decoders/png

proc expectError(payload: openArray[byte]) =
  var raised = false
  var msg = ""
  try:
    discard decodePng(payload)
  except PngDecodeError as e:
    raised = true
    msg = e.msg
  doAssert raised, "expected PngDecodeError"
  doAssert msg.len > 0, "PngDecodeError must carry a usable message"

block bad_signature:
  ## 48 bytes that look PNG-ish but flip one byte in the magic. stb_image
  ## walks every format detector and finds none matches.
  let head: array[8, byte] = [
    0x89'u8, 0x50, 0x4E, 0x46,   # 'F' instead of 'G' -- bad PNG signature
    0x0D, 0x0A, 0x1A, 0x0A
  ]
  var payload = newSeq[byte](48)
  for i in 0 ..< 8: payload[i] = head[i]
  expectError(payload)

block too_short:
  let payload = @[0x89'u8, 0x50, 0x4E, 0x47]  # only 4 bytes
  expectError(payload)

block empty:
  let payload: seq[byte] = @[]
  expectError(payload)

block random_garbage:
  # 64 bytes of nothing recognisable -- stb_image rejects.
  var payload: seq[byte] = @[]
  for i in 0 ..< 64:
    payload.add byte((i * 37 + 11) and 0xFF)
  expectError(payload)

block valid_png_with_corrupted_payload_below_minimum:
  # Real PNG signature followed by garbage that's too small to host an
  # IHDR -- stb_image's PNG path consumes the magic, fails on the chunk
  # walker, and the overall decoder reports "unknown image type" since
  # no other format matches either.
  let head: array[8, byte] = [
    0x89'u8, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A
  ]
  var payload = newSeq[byte](32)
  for i in 0 ..< 8: payload[i] = head[i]
  # Emit a chunk header claiming a huge length, no body.
  payload[8] = 0xFF; payload[9] = 0xFF; payload[10] = 0xFF; payload[11] = 0xFF
  payload[12] = byte('Z'); payload[13] = byte('Z'); payload[14] = byte('Z'); payload[15] = byte('Z')
  expectError(payload)

echo "test_decode_png_invalid OK"
