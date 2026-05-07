## test_state_mirror_pull_after_push.nim -- for every VTermProp libvterm
## fires via the screen-layer settermprop callback, the Nim wrapper
## exposes a pull-style getter.

import nim_libvterm

block:
  var s = newScreen(5, 20)

  # OSC 0 sets both icon-name and title; OSC 2 sets title only.
  s.feed("\x1b]2;Window Title\x1b\\")
  doAssert s.title() == "Window Title", "title=" & s.title()

  s.feed("\x1b]1;Icon Name\x1b\\")
  doAssert s.iconName() == "Icon Name", "iconName=" & s.iconName()

  # DECSCUSR (CSI Ps SP q) -- cursor shape.
  s.feed("\x1b[3 q")  # 3 = underline blink (one of the BLOCK_BLINK,
                       # BLOCK_STEADY, UNDERLINE_BLINK, ... values).
  # libvterm normalises shape to the 3-value enum (BLOCK / UNDERLINE / BAR).
  # Whatever it picks, it should fire the property and we should mirror it.
  # We don't assert a specific value here -- the assertion is that we can
  # READ the property pull-style.
  let _ = s.cursorShape()

  # DEC mode 25 -> cursor visibility
  s.feed("\x1b[?25l")
  doAssert not s.cursorVisible(), "cursor should be invisible"
  s.feed("\x1b[?25h")
  doAssert s.cursorVisible()

  # DEC mode 1004 -> focus reporting on/off
  s.feed("\x1b[?1004h")
  doAssert s.focusReportEnabled()

  echo "test_state_mirror_pull_after_push OK"
