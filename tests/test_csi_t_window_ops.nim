## test_csi_t_window_ops.nim -- CSI t window manipulation captured in
## windowOps log.

import nim_libvterm

block:
  var s = newScreen(2, 40)
  doAssert s.windowOps().len == 0

  s.feed("\x1b[8;30;100t")  # resize to 100x30
  let ops = s.windowOps()
  doAssert ops.len == 1
  doAssert ops[0].kind == woResize
  doAssert ops[0].args == @[30, 100]

  # CSI 21 t = "report icon-name title"
  s.feed("\x1b[21t")
  doAssert s.windowOps().len == 2
  doAssert s.windowOps()[1].kind == woGetTitle

  echo "test_csi_t_window_ops OK"
