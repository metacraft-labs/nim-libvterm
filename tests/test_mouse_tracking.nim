## test_mouse_tracking.nim -- the mouse tracking mode the application
## enabled (DEC 1000 / 1002 / 1003), as libvterm reports it.

import nim_libvterm

block:
  var s = newScreen(2, 40)
  doAssert s.mouseTracking() == mtNone

  s.feed("\x1b[?1000h")
  doAssert s.mouseTracking() == mtClick, $s.mouseTracking()

  s.feed("\x1b[?1002h")
  doAssert s.mouseTracking() == mtDrag, $s.mouseTracking()

  s.feed("\x1b[?1003h")
  doAssert s.mouseTracking() == mtMove, $s.mouseTracking()

  s.feed("\x1b[?1003l")
  doAssert s.mouseTracking() == mtNone, $s.mouseTracking()

  # the encoding is independent of the tracking mode
  s.feed("\x1b[?1006h\x1b[?1002h")
  doAssert s.mouseProtocol() == mpSgr
  doAssert s.mouseTracking() == mtDrag

  echo "test_mouse_tracking OK"
