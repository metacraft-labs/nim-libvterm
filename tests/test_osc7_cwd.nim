## test_osc7_cwd.nim -- OSC 7 CWD parses to working-directory string.
##
## Spec ref: `\\x1b]7;file://host/home/user\\x1b\\` ->
## `screen.workingDirectory() == "/home/user"`.

import nim_libvterm

block:
  var s = newScreen(2, 40)
  s.feed("\x1b]7;file://host/home/user\x1b\\")
  doAssert s.workingDirectory() == "/home/user",
    "cwd=" & s.workingDirectory()

  # Update -- a second OSC 7 should overwrite.
  s.feed("\x1b]7;file://host/tmp\x1b\\")
  doAssert s.workingDirectory() == "/tmp"

  # Bare-string fallback (some shells emit OSC 7 with just a path).
  s.feed("\x1b]7;/var/tmp\x1b\\")
  doAssert s.workingDirectory() == "/var/tmp"

  echo "test_osc7_cwd OK"
