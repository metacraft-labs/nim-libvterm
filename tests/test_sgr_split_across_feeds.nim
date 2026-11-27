## test_sgr_split_across_feeds.nim -- an SGR sequence that straddles a
## `feed` boundary must still reach the extended-state overlay.
##
## THE DEFECT THIS PINS. libvterm has no notion of the underline colour
## (CSI 58 / 59) or of the dotted / dashed underline styles (CSI 4:4 / 4:5),
## so `feedChunk` walks the byte stream itself, hands every SGR to the
## overlay's pen (`handleCsi`) and stamps the cells each text run covers with
## that pen. Before this test, an SGR whose bytes were split between two
## `feed` calls was lost to the walker: the first call met an incomplete CSI,
## stopped scanning and fed the fragment to libvterm raw, and the second call
## began mid-sequence (`2::99:102:241m...`), where no `ESC [` introduces it.
## libvterm joined the halves and applied its own attributes, but the
## overlay's pen kept its old value -- a 58 never set the colour, a 59 never
## cleared it -- and every cell drawn after it carried the wrong underline
## colour until the next SGR.
##
## Callers that read a pty in fixed-size chunks (TermAssert's `pump`) split
## sequences wherever a read happens to end, which depends on scheduling. It
## surfaced in CodeTracer's terminal snapshots as an underline colour that
## flipped between runs on a loaded host, in both directions: cells gaining
## `ul:` after a lost 59, cells losing it after a lost 58.
##
## Every case is DETERMINISTIC: the split points are chosen here, at every
## byte offset of the stream, and each split screen must equal the screen of
## one unbroken write.

import std/[strutils, unicode]
import nim_libvterm

proc ulOf(c: Cell): string =
  case c.underlineColor.kind
  of ckDefault: "default"
  of ckRgb: "rgb(" & $c.underlineColor.r & "," & $c.underlineColor.g & "," &
            $c.underlineColor.b & ")"
  of ckIndexed: "idx(" & $c.underlineColor.idx & ")"

proc cellsOf(s: Screen; rows, cols: int): seq[string] =
  for r in 0 ..< rows:
    for c in 0 ..< cols:
      let cell = s.cellAt(r, c)
      result.add $r & "," & $c & " " & $cell.rune & " " & $cell.underline &
                 " " & ulOf(cell)

proc diffOf(a, b: seq[string]): string =
  for i in 0 ..< min(a.len, b.len):
    if a[i] != b[i]: return "expected [" & a[i] & "] got [" & b[i] & "]"
  ""

proc checkEverySplit(name, stream: string; rows, cols: int) =
  var whole = newScreen(rows, cols)
  whole.feed(stream)
  let want = cellsOf(whole, rows, cols)
  var failures: seq[string]
  # Two feeds, split at every offset.
  for cut in 1 ..< stream.len:
    var s = newScreen(rows, cols)
    s.feed(stream[0 ..< cut])
    s.feed(stream[cut .. ^1])
    let d = diffOf(want, cellsOf(s, rows, cols))
    if d.len > 0: failures.add "cut " & $cut & ": " & d
  # One byte per feed: every boundary at once, several splits per sequence.
  block:
    var s = newScreen(rows, cols)
    for ch in stream: s.feed($ch)
    let d = diffOf(want, cellsOf(s, rows, cols))
    if d.len > 0: failures.add "byte-at-a-time: " & d
  doAssert failures.len == 0,
    name & ": " & $failures.len & " split(s) differ from one write:\n  " &
      failures.join("\n  ")
  echo name, " OK"

block the_control:
  # The one-write screen really has the states the splits are compared with:
  # "they match" must not be satisfiable by two screens with no colour.
  var s = newScreen(2, 20)
  s.feed("\x1b[4;58:2::99:102:241mAB\x1b[24;59mCD")
  doAssert ulOf(s.cellAt(0, 0)) == "rgb(99,102,241)", ulOf(s.cellAt(0, 0))
  doAssert ulOf(s.cellAt(0, 1)) == "rgb(99,102,241)", ulOf(s.cellAt(0, 1))
  doAssert ulOf(s.cellAt(0, 2)) == "default", ulOf(s.cellAt(0, 2))
  doAssert ulOf(s.cellAt(0, 3)) == "default", ulOf(s.cellAt(0, 3))
  echo "control OK"

block set_then_reset_underline_colour:
  # The isonim-tui shape: the underline colour in a sequence of its own after
  # the attributes, then a 59 back to the ink.
  checkEverySplit("set-then-reset",
    "\x1b[1;1H\x1b[1;4;38;2;243;243;243;48;2;64;65;104m\x1b[58:2::99:102:241m" &
    "Marked\x1b[22;24;38;2;200;200;200m\x1b[59m plain text after", 2, 40)

block reset_then_set_across_rows:
  checkEverySplit("reset-then-set",
    "\x1b[1;1H\x1b[58:5:9mone\x1b[59mtwo\x1b[2;1H\x1b[4m\x1b[58:2::1:2:3mthree" &
    "\x1b[24m\x1b[59mfour", 3, 20)

block extended_underline_style_split:
  # The other pen the overlay keeps: a dotted underline (4:4) is stamped the
  # same way, and is lost the same way when its SGR is split.
  checkEverySplit("dotted-underline",
    "\x1b[4:4mdots\x1b[24mplain\x1b[4:5mdash\x1b[0mend", 2, 30)

block hold_back_arithmetic:
  # `csiHoldBack` answers "how many bytes at the end are a control sequence
  # still waiting for its final byte".
  template hb(x: string): int = csiHoldBack(toOpenArrayByte(x, 0, x.high))
  doAssert hb("") == 0
  doAssert hb("abc") == 0
  doAssert hb("abc\x1b") == 1                       # a lone ESC
  doAssert hb("abc\x1b[") == 2
  doAssert hb("abc\x1b[58:2::99:10") == 13
  doAssert hb("abc\x1b[?20") == 5                   # a DEC private mode, cut
  doAssert hb("abc\x1b[58:2::99:102:241m") == 0     # complete
  doAssert hb("\x1b[1mabc") == 0                    # complete, text after
  doAssert hb("abc\x1b]8;;") == 0                   # an OSC is not a CSI
  doAssert hb("abc\x1b[12\r") == 0                  # C0 inside: not held
  # Malformed past the bound: passed through, not hoarded.
  doAssert hb("\x1b[" & "1;".repeat(MaxHeldCsi)) == 0
  echo "hold-back-arithmetic OK"

block pty_sized_reads:
  # The shape that flipped CodeTracer's snapshots: a whole screen of styled
  # rows, some underlined in a colour, read at the sizes a pty reader uses
  # and at sizes that split far more often.
  var stream = "\x1b[2J\x1b[H"
  for r in 0 ..< 30:
    stream.add "\x1b[" & $(r + 1) & ";1H\x1b[38;2;243;243;243;48;2;64;65;104m"
    for k in 0 ..< 6:
      stream.add "\x1b[1;4m\x1b[58:2::99:102:241mmark" & $k &
                 "\x1b[22;24m\x1b[59m plain "
  var whole = newScreen(30, 120)
  whole.feed(stream)
  let want = cellsOf(whole, 30, 120)
  var marked = 0
  for r in 0 ..< 30:
    for c in 0 ..< 120:
      if whole.cellAt(r, c).underlineColor.kind == ckRgb: inc marked
  doAssert marked == 30 * 6 * 5, "one write marked " & $marked & " cells"
  for chunk in [4096, 1024, 13, 7, 3]:
    var s = newScreen(30, 120)
    var off = 0
    while off < stream.len:
      let n = min(chunk, stream.len - off)
      s.feed(stream[off ..< off + n])
      off += n
    let d = diffOf(want, cellsOf(s, 30, 120))
    doAssert d.len == 0, "chunk " & $chunk & ": " & d
  echo "pty-sized-reads OK"
