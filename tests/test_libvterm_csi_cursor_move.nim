## test_libvterm_csi_cursor_move.nim -- CUP (cursor positioning) and
## glyph placement.
##
## Spec ref: `\\x1b[5;10HX` places "X" at row 5, col 10 (1-based in CSI;
## 0-based in our API). cursorPosition returns (5, 10) in 0-based after
## the X advances the cursor by one column.

import std/unicode
import nim_libvterm

block:
  var s = newScreen(24, 80)
  # CSI Ps;Ps H is `CUP` -- 1-based in the protocol. Row 5 col 10
  # corresponds to (4, 9) in 0-based indices.
  s.feed("\x1b[5;10HX")
  let cell = s.cellAt(4, 9)
  doAssert cell.rune == Rune(uint32('X')),
    "cellAt(4,9).rune = " & $uint32(cell.rune)
  let cur = s.cursorPosition()
  # Cursor advances past the X to col 10 (0-based).
  doAssert cur.row == 4 and cur.col == 10,
    "cursor=" & $cur

  echo "test_libvterm_csi_cursor_move OK"
