## test_osc9_notification.nim -- OSC 9 + OSC 99 notification capture +
## bounded queue.

import nim_libvterm
import nim_libvterm/extended_state

block:
  var s = newScreen(2, 40)
  s.feed("\x1b]9;Build complete\x07")
  doAssert s.notifications().len == 1
  doAssert s.notifications()[0].body == "Build complete"

  # OSC 99 -- metadata;body
  s.feed("\x1b]99;d=critical;Disk full\x07")
  doAssert s.notifications().len == 2
  doAssert s.notifications()[1].body == "Disk full"
  doAssert s.notifications()[1].metadata == "d=critical"

  echo "test_osc9_notification basic OK"

block:
  ## Bounded queue: feeding 2000 OSC 9 notifications should retain only
  ## the most recent 1024 (the default cap), with the oldest 976 dropped.
  var s = newScreen(2, 40)
  for i in 0 ..< 2000:
    s.feed("\x1b]9;n" & $i & "\x07")
  let notes = s.notifications()
  doAssert notes.len == 1024,
    "expected 1024 retained notifications, got " & $notes.len
  # Oldest retained is body "n976"; newest is "n1999".
  doAssert notes[0].body == "n976",
    "oldest retained should be n976, got " & notes[0].body
  doAssert notes[^1].body == "n1999",
    "newest should be n1999, got " & notes[^1].body
  # Spot-check ordering at midpoint.
  doAssert notes[500].body == "n" & $(976 + 500)

  echo "test_osc9_notification bounded-queue OK"
