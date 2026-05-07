## test_mouse_protocol.nim -- mouse protocol selectors (1006 SGR, 1015
## URXVT, 1016 pixel-position).

import nim_libvterm

block:
  var s = newScreen(2, 40)
  doAssert s.mouseProtocol() == mpNone

  s.feed("\x1b[?1006h")
  doAssert s.mouseProtocol() == mpSgr

  s.feed("\x1b[?1016h")
  doAssert s.mouseProtocol() == mpPixel

  s.feed("\x1b[?1016l")
  doAssert s.mouseProtocol() == mpSgr  # falls back

  echo "test_mouse_protocol OK"
