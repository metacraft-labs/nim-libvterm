## test_modify_other_keys.nim -- xterm modify-other-keys CSI > 4 ; N m.

import nim_libvterm

block:
  var s = newScreen(2, 40)
  doAssert s.modifyOtherKeys() == 0
  s.feed("\x1b[>4;2m")
  doAssert s.modifyOtherKeys() == 2
  s.feed("\x1b[>4;0m")
  doAssert s.modifyOtherKeys() == 0
  echo "test_modify_other_keys OK"
