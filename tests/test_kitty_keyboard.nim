## test_kitty_keyboard.nim -- Kitty keyboard progressive enhancement
## protocol push/pop.
##
## CSI = N u   pushes a new stack frame with flag set N
## CSI < N u   pushes a new stack frame with flag set N (alias)
## CSI > N u   pops one stack frame
## CSI ? u     queries (we don't actuate replies)

import nim_libvterm

block:
  var s = newScreen(2, 40)
  doAssert s.kittyKeyboardFlags() == {}

  s.feed("\x1b[=1u")  # disambiguate flag = 0x1
  doAssert kkfDisambiguate in s.kittyKeyboardFlags()

  s.feed("\x1b[=3u")  # 0x3 = disambiguate + report-events
  doAssert s.kittyKeyboardFlags() == {kkfDisambiguate, kkfReportEvents}

  echo "test_kitty_keyboard basic OK"

block:
  ## Stack push/pop: feed two pushes then a pop and verify the top
  ## reflects the EARLIER push, not the most recent (because that one
  ## got popped).
  var s = newScreen(2, 40)
  doAssert s.kittyKeyboardFlags() == {}

  # First push: flags = 0x1 (disambiguate), mode = 1 (replace)
  s.feed("\x1b[=1;1u")
  doAssert s.kittyKeyboardFlags() == {kkfDisambiguate}

  # Second push: flags = 0x4 (report-alternates), mode = 1
  s.feed("\x1b[=4;1u")
  doAssert s.kittyKeyboardFlags() == {kkfReportAlternates}

  # Pop one frame -- should reveal the first push.
  s.feed("\x1b[>1u")
  doAssert s.kittyKeyboardFlags() == {kkfDisambiguate},
    "after pop, top should reflect the first push, got " &
    $s.kittyKeyboardFlags()

  # Pop again -- should reveal the base {} frame.
  s.feed("\x1b[>1u")
  doAssert s.kittyKeyboardFlags() == {}

  # Extra pop on a 1-frame stack must NOT empty it (we always keep the
  # base frame so getters never have to special-case).
  s.feed("\x1b[>1u")
  doAssert s.kittyKeyboardFlags() == {}

  echo "test_kitty_keyboard stack OK"
