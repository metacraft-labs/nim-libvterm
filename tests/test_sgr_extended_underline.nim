## test_sgr_extended_underline.nim -- modern underline-style SGR
## sub-parameter parsing through real-byte feed paths.
##
## Coverage:
##   * `CSI 4 m`      -- legacy single underline (libvterm-tracked).
##   * `CSI 4:0 m`    -- explicit underline-off (libvterm-tracked).
##   * `CSI 4:1 m`    -- single (libvterm-tracked).
##   * `CSI 4:2 m`    -- double (libvterm-tracked).
##   * `CSI 4:3 m`    -- curly (libvterm-tracked).
##   * `CSI 4:4 m`    -- dotted (extended-state grid; libvterm's
##                       2-bit field can't represent it).
##   * `CSI 4:5 m`    -- dashed (extended-state grid).
##   * `CSI 24 m`     -- underline off after extended-style run.
##
## Each block feeds a real byte sequence through `Screen.feed` and
## inspects the resulting `Cell.underline` (and `Cell.extUnderline`
## for dotted/dashed). No mocks; no shortcuts.

import std/unicode
import nim_libvterm

block legacy_single:
  var s = newScreen(2, 40)
  s.feed("\x1b[4mA")
  let c = s.cellAt(0, 0)
  doAssert c.rune == Rune(uint32('A'))
  doAssert c.underline == usSingle, "legacy CSI 4 m: " & $c.underline
  doAssert c.extUnderline == usNone

block sub_off:
  var s = newScreen(2, 40)
  # Set curly first, then explicit underline-off via 4:0
  s.feed("\x1b[4:3mA\x1b[4:0mB")
  let a = s.cellAt(0, 0)
  let b = s.cellAt(0, 1)
  doAssert a.rune == Rune(uint32('A'))
  doAssert a.underline == usCurly, "expected curly on A, got " & $a.underline
  doAssert b.rune == Rune(uint32('B'))
  doAssert b.underline == usNone, "expected none on B, got " & $b.underline

block sub_single:
  var s = newScreen(2, 40)
  s.feed("\x1b[4:1mA")
  let c = s.cellAt(0, 0)
  doAssert c.rune == Rune(uint32('A'))
  doAssert c.underline == usSingle, "expected single, got " & $c.underline

block sub_double:
  var s = newScreen(2, 40)
  s.feed("\x1b[4:2mA")
  let c = s.cellAt(0, 0)
  doAssert c.rune == Rune(uint32('A'))
  doAssert c.underline == usDouble, "expected double, got " & $c.underline

block sub_curly:
  var s = newScreen(2, 40)
  s.feed("\x1b[4:3mA")
  let c = s.cellAt(0, 0)
  doAssert c.rune == Rune(uint32('A'))
  doAssert c.underline == usCurly, "expected curly, got " & $c.underline

block sub_dotted:
  var s = newScreen(2, 40)
  s.feed("\x1b[4:4mA")
  let c = s.cellAt(0, 0)
  doAssert c.rune == Rune(uint32('A'))
  doAssert c.extUnderline == usDotted, "extUnderline=" & $c.extUnderline
  # `Cell.underline` mirrors extUnderline so consumers that just check
  # `cell.underline` get the right answer for dotted/dashed styles too.
  doAssert c.underline == usDotted, "underline=" & $c.underline

block sub_dashed:
  var s = newScreen(2, 40)
  s.feed("\x1b[4:5mA")
  let c = s.cellAt(0, 0)
  doAssert c.rune == Rune(uint32('A'))
  doAssert c.extUnderline == usDashed, "extUnderline=" & $c.extUnderline
  doAssert c.underline == usDashed, "underline=" & $c.underline

block curly_then_off:
  ## Verifies CSI 24 m turns extended underlines off so subsequent
  ## cells show as ulNone. Cells written under the curly run keep
  ## their style.
  var s = newScreen(2, 40)
  s.feed("\x1b[4:3mfoo\x1b[24mbar")
  for col in 0 .. 2:  # f, o, o
    let c = s.cellAt(0, col)
    doAssert c.underline == usCurly,
      "col=" & $col & " expected curly, got " & $c.underline
  for col in 3 .. 5:  # b, a, r
    let c = s.cellAt(0, col)
    doAssert c.underline == usNone,
      "col=" & $col & " expected none, got " & $c.underline

block dotted_then_off:
  ## Same as curly_then_off but for the extended-state-tracked dotted
  ## variant -- exercises the per-cell extUnderlineGrid stamping path.
  var s = newScreen(2, 40)
  s.feed("\x1b[4:4mfoo\x1b[24mbar")
  for col in 0 .. 2:
    let c = s.cellAt(0, col)
    doAssert c.extUnderline == usDotted,
      "col=" & $col & " expected dotted, got " & $c.extUnderline
    doAssert c.underline == usDotted,
      "col=" & $col & " expected dotted, got " & $c.underline
  for col in 3 .. 5:
    let c = s.cellAt(0, col)
    doAssert c.extUnderline == usNone,
      "col=" & $col & " expected none, got " & $c.extUnderline
    doAssert c.underline == usNone,
      "col=" & $col & " expected none, got " & $c.underline

block dashed_run_among_plain:
  ## A dashed run in the middle of plain text -- verifies the per-cell
  ## grid stamps only the dashed cells.
  var s = newScreen(2, 40)
  s.feed("plain\x1b[4:5mDASH\x1b[24mtail")
  for col in 0 .. 4:  # plain
    let c = s.cellAt(0, col)
    doAssert c.underline == usNone, "plain col=" & $col
  for col in 5 .. 8:  # DASH
    let c = s.cellAt(0, col)
    doAssert c.extUnderline == usDashed,
      "DASH col=" & $col & " ext=" & $c.extUnderline
  for col in 9 .. 12:  # tail
    let c = s.cellAt(0, col)
    doAssert c.underline == usNone, "tail col=" & $col

echo "test_sgr_extended_underline OK"
