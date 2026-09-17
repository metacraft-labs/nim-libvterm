## test_utf8_split_across_feeds.nim -- a multi-byte sequence that straddles a
## `feed` boundary must survive it.
##
## THE DEFECT THIS PINS. libvterm keeps FIVE UTF-8 decoder instances -- one per
## G0..G3 charset slot plus a dedicated `encoding_utf8` -- and
## `vendor/libvterm/src/state.c:314` chooses between them ONCE PER TEXT RUN,
## from the high bit of the run's first byte:
##
##     !(bytes[eaten] & 0x80) ? &state->encoding[state->gl_set]
##                            : &state->encoding_utf8
##
## In UTF-8 mode all four G-slots are UTF-8 decoders too, each with its own
## `data` block. So a sequence split across two `vterm_input_write` calls is
## decoded by two DIFFERENT instances: the first half's `bytes_remaining` is
## stranded in `encoding[gl_set]` (chosen because that run began on an ASCII
## byte), and the continuation bytes that arrive next go to `encoding_utf8`,
## which has no state and emits U+FFFD for each of them. The stranded half then
## corrupts the next ASCII-initial run as well.
##
## Any caller that reads a pty in fixed-size chunks splits sequences routinely
## -- TermAssert's `pump` reads 4096 bytes at a time -- so this was a silent
## glyph loss in ordinary use. `feed` now holds an incomplete trailing sequence
## back and prepends it to the next call.
##
## Every case below is DETERMINISTIC: the split points are chosen by this file
## rather than by a scheduler, which is what a regression test for this has to
## be. (An end-to-end screen comparison over a real pty does NOT reliably
## reproduce it -- whether a read lands mid-sequence is a scheduling accident.)

import std/[strutils, unicode]
import nim_libvterm

const Replacement = 0xFFFD

proc badCells(s: Screen; rows, cols: int): seq[string] =
  for r in 0 ..< rows:
    for c in 0 ..< cols:
      if s.cellAt(r, c).rune.int32 == Replacement:
        result.add "(" & $r & "," & $c & ")"

block hold_back_arithmetic:
  # `utf8HoldBack` answers "how many bytes at the end are an incomplete
  # sequence". Complete input holds nothing back; every truncation of a 2-, 3-
  # and 4-byte sequence holds back exactly what it has.
  doAssert utf8HoldBack(toOpenArrayByte("", 0, -1)) == 0
  doAssert utf8HoldBack(toOpenArrayByte("abc", 0, 2)) == 0
  doAssert utf8HoldBack(toOpenArrayByte("a\xC3\xA9", 0, 2)) == 0   # complete é
  doAssert utf8HoldBack(toOpenArrayByte("a\xC3", 0, 1)) == 1       # é, cut
  doAssert utf8HoldBack(toOpenArrayByte("\xE2\x96\x92", 0, 2)) == 0  # ▒
  doAssert utf8HoldBack(toOpenArrayByte("\xE2\x96", 0, 1)) == 2
  doAssert utf8HoldBack(toOpenArrayByte("\xE2", 0, 0)) == 1
  doAssert utf8HoldBack(toOpenArrayByte("\xF0\x9F\x99\x82", 0, 3)) == 0  # 🙂
  doAssert utf8HoldBack(toOpenArrayByte("\xF0\x9F\x99", 0, 2)) == 3
  # Malformed input is libvterm's to report, not this function's to hoard:
  # a lone continuation byte and an invalid lead byte both hold back nothing,
  # so a stream that can never be completed is still passed through.
  doAssert utf8HoldBack(toOpenArrayByte("\x80", 0, 0)) == 0
  doAssert utf8HoldBack(toOpenArrayByte("\x80\x80\x80\x80", 0, 3)) == 0
  doAssert utf8HoldBack(toOpenArrayByte("a\xFF", 0, 1)) == 0
  echo "hold-back-arithmetic OK"

block ascii_initial_run_split_one_byte_short:
  # THE MINIMAL REPRODUCTION. The run begins on an ASCII space, so libvterm
  # picks `encoding[gl_set]`; the split leaves one continuation byte to arrive
  # on its own, where `encoding_utf8` gets it instead.
  let stream = "\x1b[1;1H" & " " & "▒".repeat(10)
  let cut = stream.len - 1
  var s = newScreen(3, 20)
  s.feed(stream[0 ..< cut])
  s.feed(stream[cut .. ^1])
  let bad = badCells(s, 3, 20)
  doAssert bad.len == 0, "U+FFFD at " & bad.join(" ")
  doAssert $s.cellAt(0, 10).rune == "▒", "cell (0,10) is " & $s.cellAt(0, 10).rune
  echo "ascii-initial-run-split OK"

block the_stranded_half_does_not_corrupt_the_next_run:
  # The second symptom: a stranded `bytes_remaining` makes `decode_utf8` emit a
  # SECOND U+FFFD when it next meets an ASCII byte. Without the hold-back this
  # put one at (0,10) and another at (1,0).
  let stream = "\x1b[1;1H" & " " & "▒".repeat(10)
  let cut = stream.len - 1
  var s = newScreen(3, 20)
  s.feed(stream[0 ..< cut])
  s.feed(stream[cut .. ^1])
  s.feed("\x1b[2;1Habc")
  let bad = badCells(s, 3, 20)
  doAssert bad.len == 0, "U+FFFD at " & bad.join(" ")
  doAssert $s.cellAt(1, 0).rune == "a", "cell (1,0) is " & $s.cellAt(1, 0).rune
  echo "next-run-uncorrupted OK"

block every_chunk_size_agrees_with_one_shot:
  # A whole screen of three-byte glyphs behind ASCII row labels -- the shape a
  # terminal application actually emits -- fed at the chunk size a pty reader
  # uses (4096) and at two sizes that split far more often. Each must produce
  # the SAME SCREEN as one unbroken write, which is the property callers rely
  # on and the one that was false.
  var stream = "\x1b[2J\x1b[H"
  for r in 0 ..< 40:
    var line = "base row " & align($r, 2, '0') & " "
    while line.runeLen < 120:
      line.add "▒"
    stream.add "\x1b[" & $(r + 1) & ";1H" & line

  var oneShot = newScreen(40, 120)
  oneShot.feed(stream)
  # The control: the reference screen is fully painted, so "they match" cannot
  # be satisfied by two blank screens.
  doAssert badCells(oneShot, 40, 120).len == 0
  var painted = 0
  for r in 0 ..< 40:
    for c in 0 ..< 120:
      if oneShot.cellAt(r, c).rune.int32 != 0: inc painted
  doAssert painted == 40 * 120, "one-shot painted " & $painted & " of 4800"

  for chunk in [4096, 1024, 7, 3, 1]:
    var s = newScreen(40, 120)
    var off = 0
    while off < stream.len:
      let n = min(chunk, stream.len - off)
      s.feed(stream[off ..< off + n])
      off += n
    var differing = 0
    for r in 0 ..< 40:
      for c in 0 ..< 120:
        if s.cellAt(r, c).rune != oneShot.cellAt(r, c).rune: inc differing
    doAssert differing == 0,
      $chunk & "-byte chunks: " & $differing & " cell(s) differ from the " &
      "one-shot feed; U+FFFD at " & badCells(s, 40, 120).join(" ")
  echo "chunked-feed-equals-one-shot OK (4096, 1024, 7, 3, 1)"

block a_trailing_partial_sequence_is_completed_not_dropped:
  # The hold-back must be a DELAY, not a discard: the glyph appears as soon as
  # the bytes that finish it arrive, however many calls that takes.
  var s = newScreen(1, 10)
  s.feed("\x1b[2J\x1b[H")
  s.feed("\xF0")
  s.feed("\x9F")
  s.feed("\x99")
  doAssert s.cellAt(0, 0).rune.int32 == 0, "emitted before the sequence closed"
  s.feed("\x82")
  doAssert $s.cellAt(0, 0).rune == "🙂", "cell (0,0) is " & $s.cellAt(0, 0).rune
  echo "byte-at-a-time-completion OK"

echo "test_utf8_split_across_feeds OK"
