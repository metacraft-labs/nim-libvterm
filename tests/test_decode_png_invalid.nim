## test_decode_png_invalid.nim -- malformed-input rejection tests for the
## PNG decoder.
##
## Each `block` constructs a deliberately broken PNG (or non-PNG) and
## asserts that `decodePng` raises `PngDecodeError` with a usable message.
## Nothing here is mock-y: the bad bytes really would corrupt a PNG
## reader; real-world fuzz inputs hit similar shapes.

import std/strutils
import nim_libvterm/decoders/png
import ./test_helpers

proc expectError(payload: openArray[byte]; needle: string) =
  var raised = false
  var msg = ""
  try:
    discard decodePng(payload)
  except PngDecodeError as e:
    raised = true
    msg = e.msg
  doAssert raised, "expected PngDecodeError; needle=" & needle
  doAssert msg.len > 0
  if needle.len > 0:
    doAssert needle in msg,
      "needle '" & needle & "' not in error message: " & msg

block bad_signature:
  ## We need a payload >= the minimum-size threshold (32 bytes) so the
  ## decoder gets past the size check and reaches the signature check.
  var payload = @[
    0x89'u8, 0x50, 0x4E, 0x46,  # 'F' instead of 'G' -- bad signature
    0x0D, 0x0A, 0x1A, 0x0A
  ]
  for _ in 0 ..< 40:
    payload.add 0'u8
  expectError(payload, "signature")

block too_short:
  let payload = @[0x89'u8, 0x50, 0x4E, 0x47]  # only 4 bytes
  expectError(payload, "")

block crc_mismatch:
  # Build a valid 1x1 RGBA PNG, then flip a bit in the IDAT CRC.
  let pixels = @[byte(255), byte(0), byte(0), byte(255)]
  var png = encodePng(1, 1, 6, pixels)
  # Find IDAT chunk: after signature (8) + IHDR length-prefix (4) +
  # IHDR type (4) + 13-byte payload + 4-byte CRC = 33 bytes.
  # Then IDAT length(4) + type(4) + data(N) + CRC(4).
  let idatStart = 8 + 4 + 4 + 13 + 4
  let idatLen = (int(png[idatStart]) shl 24) or
                (int(png[idatStart + 1]) shl 16) or
                (int(png[idatStart + 2]) shl 8) or
                int(png[idatStart + 3])
  let crcOff = idatStart + 4 + 4 + idatLen
  png[crcOff] = png[crcOff] xor 0xFF'u8  # corrupt CRC
  expectError(png, "CRC32")

block missing_iend:
  # Truncate a valid PNG before its IEND.
  let pixels = @[byte(0), byte(0), byte(0), byte(255)]
  var png = encodePng(1, 1, 6, pixels)
  # Drop the trailing 12 bytes (IEND length+type+empty payload+CRC).
  png.setLen(png.len - 12)
  expectError(png, "IEND")

block unsupported_color_type:
  # Hand-roll an IHDR with color type 4 (greyscale + alpha).
  var ihdr: seq[byte] = @[]
  be32Bytes(ihdr, 4)             # width
  be32Bytes(ihdr, 4)             # height
  ihdr.add 8'u8                  # bit depth
  ihdr.add 4'u8                  # color type 4 -- unsupported
  ihdr.add 0'u8
  ihdr.add 0'u8
  ihdr.add 0'u8

  var png: seq[byte] = @[]
  for b in [0x89'u8, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]:
    png.add b
  emitPngChunk(png, "IHDR", ihdr)
  emitPngChunk(png, "IEND", [])
  expectError(png, "greyscale")

block interlaced_rejected:
  # Hand-roll an Adam7-interlaced IHDR.
  var ihdr: seq[byte] = @[]
  be32Bytes(ihdr, 4)
  be32Bytes(ihdr, 4)
  ihdr.add 8'u8
  ihdr.add 6'u8   # RGBA
  ihdr.add 0'u8
  ihdr.add 0'u8
  ihdr.add 1'u8   # interlace = Adam7

  var png: seq[byte] = @[]
  for b in [0x89'u8, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]:
    png.add b
  emitPngChunk(png, "IHDR", ihdr)
  emitPngChunk(png, "IEND", [])
  expectError(png, "interlaced")

echo "test_decode_png_invalid OK"
