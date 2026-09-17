## test_wide_glyph_continuation_cell.nim -- the trailing half of a width-2 cell.
##
## libvterm stamps `chars[0] = (uint32_t)-1` on the cell to the right of a
## double-width glyph (`vendor/libvterm/src/screen.c:191`) and reads that
## sentinel, and only that sentinel, back to answer `width` for the LEADING
## half (`screen.c:1019`). `vterm_screen_get_cell` copies `chars` verbatim, so
## a query for the trailing half ITSELF yields `chars[0] == 0xFFFFFFFF`.
##
## 0xFFFFFFFF is not a codepoint. Turning it into a `Rune` raised
##
##     RangeDefect: value out of range: 4294967295 notin -2147483648 .. 2147483647
##
## on every screen containing a CJK glyph or a wide emoji -- so such a glyph was
## not merely mis-reported, it was UNOBSERVABLE through `cellAt` and through
## every caller that walks a whole screen with it.
##
## `cellAt` now reports the trailing half as `rune = 0, width = 0`, which makes
## "skip the cells whose width is 0" a correct screen walk.

import std/unicode
import nim_libvterm

block cjk_pair:
  var s = newScreen(3, 20)
  s.feed("\x1b[2J\x1b[H┌世界─┐")

  # The leading half: the wide rune, and libvterm's own width answer.
  let lead = s.cellAt(0, 1)
  doAssert $lead.rune == "世", "leading half rune: " & $lead.rune
  doAssert lead.width == 2, "leading half width: " & $lead.width

  # The trailing half. Before the fix, THIS LINE RAISED.
  let ghost = s.cellAt(0, 2)
  doAssert ghost.rune.int32 == 0, "trailing half rune: " & $ghost.rune.int32
  doAssert ghost.width == 0, "trailing half width: " & $ghost.width

  # And the glyph after the pair is where the two-column claim puts it, so the
  # test cannot pass by reporting every cell as a ghost.
  doAssert $s.cellAt(0, 3).rune == "界"
  doAssert s.cellAt(0, 3).width == 2
  doAssert s.cellAt(0, 4).width == 0
  doAssert $s.cellAt(0, 5).rune == "─"
  doAssert s.cellAt(0, 5).width == 1
  doAssert $s.cellAt(0, 6).rune == "┐"

  # A whole-screen walk completes -- the property every snapshot encoder needs.
  var narrow, wide, ghosts = 0
  for r in 0 ..< 3:
    for c in 0 ..< 20:
      case s.cellAt(r, c).width
      of 0: inc ghosts
      of 2: inc wide
      else: inc narrow
  doAssert wide == 2, "wide cells: " & $wide
  doAssert ghosts == 2, "ghost cells: " & $ghosts
  doAssert narrow == 3 * 20 - 4
  echo "cjk-pair OK (", wide, " wide, ", ghosts, " ghost)"

block four_byte_emoji:
  # Four UTF-8 bytes rather than three, and still width 2: the sentinel path is
  # about the WIDTH table, not about the encoding length.
  var s = newScreen(1, 10)
  s.feed("\x1b[2J\x1b[H🙂x")
  doAssert s.cellAt(0, 0).width == 2, "emoji width: " & $s.cellAt(0, 0).width
  doAssert s.cellAt(0, 1).width == 0
  doAssert s.cellAt(0, 1).rune.int32 == 0
  doAssert $s.cellAt(0, 2).rune == "x"
  echo "four-byte-emoji OK"

block plain_ascii_is_untouched:
  # The negative twin: an ordinary narrow screen must report NO ghosts, or the
  # assertions above would be satisfied by a `cellAt` that returned width 0 for
  # everything.
  var s = newScreen(2, 8)
  s.feed("\x1b[2J\x1b[Habcdefgh")
  for c in 0 ..< 8:
    doAssert s.cellAt(0, c).width == 1, "ascii cell " & $c & " width " &
      $s.cellAt(0, c).width
  echo "plain-ascii OK"

echo "test_wide_glyph_continuation_cell OK"
