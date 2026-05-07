## test_libvterm_basic_hello.nim -- trivial round-trip into the real libvterm.
##
## Spec ref (codetracer-specs `Front-Ends/IsoNim/isonim-tui.milestones.org`,
## section "L2: nim-libvterm", real-stack tests):
##   feed("hello\\n") -> contents() row 0 starts with "hello".

import std/unicode
import nim_libvterm
import ./test_helpers

block:
  var s = newScreen(24, 80)
  s.feed("hello\n")
  let row0 = rowAsString(s, 0)
  doAssert row0 == "hello", "row0='" & row0 & "'"
  doAssert s.cellAt(0, 0).rune == Rune(uint32('h')), "cell[0,0]"
  doAssert s.cellAt(0, 4).rune == Rune(uint32('o')), "cell[0,4]"
  doAssert s.containsText("hello")
  echo "test_libvterm_basic_hello OK"
