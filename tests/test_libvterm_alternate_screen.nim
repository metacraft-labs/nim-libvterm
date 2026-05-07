## test_libvterm_alternate_screen.nim -- DEC mode 1049 (and 1047) switch
## to/from alt-screen and restore primary content.
##
## Spec ref: `\\x1b[?1049h` switches to alt screen; `\\x1b[?1049l` restores;
## visible content matches the pre-enter state.

import nim_libvterm
import ./test_helpers

block:
  var s = newScreen(5, 20)
  s.feed("primary text here\n")
  doAssert rowAsString(s, 0) == "primary text here"

  # Enter alt screen, write something there.
  s.feed("\x1b[?1049h")
  doAssert s.altScreenActive

  # Move cursor home and clear screen so primary doesn't bleed through.
  s.feed("\x1b[H\x1b[2J")
  s.feed("alt screen body")
  doAssert rowAsString(s, 0) == "alt screen body"

  # Leave alt screen.
  s.feed("\x1b[?1049l")
  doAssert not s.altScreenActive
  doAssert rowAsString(s, 0) == "primary text here",
    "row0=" & rowAsString(s, 0)

  echo "test_libvterm_alternate_screen OK"
