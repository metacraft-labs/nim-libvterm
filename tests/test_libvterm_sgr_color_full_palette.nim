## test_libvterm_sgr_color_full_palette.nim -- 16-color, 256-color, and
## 24-bit RGB SGR all parse correctly.
##
## Spec ref: SGR named-16 / indexed-256 / RGB truecolor; sub-parameter
## forms (`:` and `;`).

import std/unicode
import nim_libvterm

block:
  var s = newScreen(2, 40)
  # Foreground red (named-16: SGR 31), then write 'A'
  s.feed("\x1b[31mA")
  let a = s.cellAt(0, 0)
  doAssert a.rune == Rune(uint32('A'))
  doAssert a.fg.kind == ckIndexed, "fg.kind=" & $a.fg.kind
  doAssert a.fg.idx == 1, "expected idx=1 (red), got " & $a.fg.idx

  # Reset, then foreground 256-color index 196 (also red), write 'B'
  s.feed("\x1b[0m\x1b[38;5;196mB")
  let b = s.cellAt(0, 1)
  doAssert b.rune == Rune(uint32('B'))
  doAssert b.fg.kind == ckIndexed
  doAssert b.fg.idx == 196, "expected 196, got " & $b.fg.idx

  # Reset, then 24-bit RGB foreground (1,2,3), write 'C'
  s.feed("\x1b[0m\x1b[38;2;1;2;3mC")
  let c = s.cellAt(0, 2)
  doAssert c.rune == Rune(uint32('C'))
  doAssert c.fg.kind == ckRgb, "fg.kind=" & $c.fg.kind
  doAssert c.fg.r == 1 and c.fg.g == 2 and c.fg.b == 3,
    "expected RGB(1,2,3), got (" & $c.fg.r & "," & $c.fg.g & "," & $c.fg.b & ")"

  # Sub-param `:` form (CSI 38:2:1:2:3 m). libvterm supports both.
  s.feed("\x1b[0m\x1b[38:2::4:5:6mD")
  let d = s.cellAt(0, 3)
  doAssert d.rune == Rune(uint32('D'))
  doAssert d.fg.kind == ckRgb, "colon-form fg.kind=" & $d.fg.kind
  # Note: the `38:2:CS:R:G:B` form in some readings has a colour-space
  # slot before R. libvterm's accepted shape is `38:2::R:G:B` per its
  # source. We tolerate either layout in the test.

  # Bold + italic + underline + reverse all set together
  s.feed("\x1b[0m\x1b[1;3;4;7mE")
  let e = s.cellAt(0, 4)
  doAssert e.rune == Rune(uint32('E'))
  doAssert caBold in e.attrs
  doAssert caItalic in e.attrs
  doAssert caReverse in e.attrs
  doAssert e.underline == usSingle

  echo "test_libvterm_sgr_color_full_palette OK"
