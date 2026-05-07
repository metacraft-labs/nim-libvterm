## test_libvterm_resize_round_trip.nim -- resize() changes dimensions and
## subsequent feeds wrap correctly.

import std/unicode
import nim_libvterm

block:
  var s = newScreen(24, 80)
  doAssert s.size() == (rows: 24, cols: 80)

  s.resize(50, 200)
  doAssert s.size() == (rows: 50, cols: 200)

  # After a resize, subsequent feeds should still work and respect the
  # new column count. Write 100 'A's at row 5; they should all fit on one
  # line because cols=200.
  s.feed("\x1b[6;1H")  # CUP to row 6 col 1 (1-based -> 5,0 in 0-based)
  let n = 100
  var bulk = ""
  for _ in 0 ..< n: bulk.add 'A'
  s.feed(bulk)

  for c in 0 ..< n:
    doAssert s.cellAt(5, c).rune == Rune(uint32('A')),
      "cellAt(5, " & $c & ") missing 'A'"
  # Cell at col n (0-based) should be empty.
  doAssert s.cellAt(5, n).rune == Rune(0)

  echo "test_libvterm_resize_round_trip OK"
