## test_dec_2026_synchronized_output.nim -- DEC mode 2026 synchronized
## output. libvterm itself drops this CSI; we capture it via the
## state-layer fallback.

import nim_libvterm

block:
  var s = newScreen(2, 40)
  doAssert not s.synchronizedOutput()

  s.feed("\x1b[?2026h")
  doAssert s.synchronizedOutput(),
    "expected sync-output to be true after CSI ?2026 h"

  s.feed("\x1b[?2026l")
  doAssert not s.synchronizedOutput()

  echo "test_dec_2026_synchronized_output OK"
