## test_kitty_keyboard.nim -- Kitty keyboard progressive enhancement.
##
## Spec: https://sw.kovidgoyal.net/kitty/keyboard-protocol/#progressive-enhancement
##
## CSI > flags u          pushes `flags`
## CSI < number u         pops `number` entries (default 1); popping past
##                        the bottom resets all flags
## CSI = flags ; mode u   modifies the current entry: 1 set (default),
##                        2 or, 3 and-not
## CSI ? u                queries (Screen has no reply channel)
##
## The main and alternate screens keep independent stacks.

import nim_libvterm

block:
  ## A push makes its flags current; a pop restores the entry below.
  var s = newScreen(2, 40)
  doAssert s.kittyKeyboardFlags() == {}

  s.feed("\x1b[>1u")
  doAssert s.kittyKeyboardFlags() == {kkfDisambiguate}

  s.feed("\x1b[>12u")  # 0x4 | 0x8
  doAssert s.kittyKeyboardFlags() == {kkfReportAlternates, kkfReportAllKeys}

  s.feed("\x1b[<u")
  doAssert s.kittyKeyboardFlags() == {kkfDisambiguate},
    "after one pop, the first push should be current, got " &
    $s.kittyKeyboardFlags()

  s.feed("\x1b[<1u")
  doAssert s.kittyKeyboardFlags() == {}

  # Push with the flags omitted pushes 0.
  s.feed("\x1b[>31u\x1b[>u")
  doAssert s.kittyKeyboardFlags() == {}
  s.feed("\x1b[<u")
  doAssert s.kittyKeyboardFlags() ==
    {kkfDisambiguate, kkfReportEvents, kkfReportAlternates, kkfReportAllKeys,
     kkfReportText}

  echo "test_kitty_keyboard push/pop OK"

block:
  ## CSI < n u pops n entries at once.
  var s = newScreen(2, 40)
  s.feed("\x1b[>1u\x1b[>2u\x1b[>4u\x1b[>8u")
  doAssert s.kittyKeyboardFlags() == {kkfReportAllKeys}

  s.feed("\x1b[<3u")
  doAssert s.kittyKeyboardFlags() == {kkfDisambiguate},
    "CSI < 3 u should pop three entries, got " & $s.kittyKeyboardFlags()

  echo "test_kitty_keyboard multi-pop OK"

block:
  ## Popping past the bottom empties the stack and resets all flags, and
  ## that includes flags set with `=` before anything was pushed.
  var s = newScreen(2, 40)
  s.feed("\x1b[=3u\x1b[>1u\x1b[>2u")
  s.feed("\x1b[<5u")
  doAssert s.kittyKeyboardFlags() == {}

  # The stack is usable again afterwards.
  s.feed("\x1b[>16u")
  doAssert s.kittyKeyboardFlags() == {kkfReportText}
  s.feed("\x1b[<u")
  doAssert s.kittyKeyboardFlags() == {}

  # A pop on an empty stack leaves the flags reset.
  s.feed("\x1b[<u")
  doAssert s.kittyKeyboardFlags() == {}

  echo "test_kitty_keyboard pop past bottom OK"

block:
  ## `=` modifies the current entry in place; it never pushes.
  var s = newScreen(2, 40)
  s.feed("\x1b[>1u")

  # mode 1: replace.
  s.feed("\x1b[=6;1u")
  doAssert s.kittyKeyboardFlags() == {kkfReportEvents, kkfReportAlternates}

  # mode omitted: defaults to 1.
  s.feed("\x1b[=8u")
  doAssert s.kittyKeyboardFlags() == {kkfReportAllKeys}

  # mode 2: set the given bits, keep the rest.
  s.feed("\x1b[=3;2u")
  doAssert s.kittyKeyboardFlags() ==
    {kkfDisambiguate, kkfReportEvents, kkfReportAllKeys}

  # mode 3: clear the given bits, keep the rest.
  s.feed("\x1b[=9;3u")
  doAssert s.kittyKeyboardFlags() == {kkfReportEvents}

  # None of those pushed: a single pop returns to the base entry.
  s.feed("\x1b[<u")
  doAssert s.kittyKeyboardFlags() == {},
    "`=` must modify the current entry, not push; got " &
    $s.kittyKeyboardFlags()

  # With nothing pushed, `=` modifies the bottom entry.
  s.feed("\x1b[=1u")
  doAssert s.kittyKeyboardFlags() == {kkfDisambiguate}
  s.feed("\x1b[>2u\x1b[<u")
  doAssert s.kittyKeyboardFlags() == {kkfDisambiguate}

  echo "test_kitty_keyboard modify OK"

block:
  ## The query neither pushes, pops nor modifies.
  var s = newScreen(2, 40)
  s.feed("\x1b[>1u\x1b[>5u")
  s.feed("\x1b[?u")
  doAssert s.kittyKeyboardFlags() == {kkfDisambiguate, kkfReportAlternates}
  s.feed("\x1b[<u")
  doAssert s.kittyKeyboardFlags() == {kkfDisambiguate}

  echo "test_kitty_keyboard query OK"

block:
  ## The stack is bounded: a push onto a full stack evicts the oldest
  ## entry, so popping everything still ends with the flags reset and
  ## the newest entries are the ones kept.
  var s = newScreen(2, 40)
  for i in 1 .. 20:
    s.feed("\x1b[>" & $(i mod 32) & "u")
  doAssert s.kittyKeyboardFlags() == {kkfReportAlternates, kkfReportText}  # 20
  s.feed("\x1b[<u")
  doAssert s.kittyKeyboardFlags() == {kkfDisambiguate, kkfReportEvents,
                                     kkfReportText}  # 19
  # Eight entries are kept (13 .. 20), so six more pops reach 13 and the
  # next one empties the stack.
  s.feed("\x1b[<6u")
  doAssert s.kittyKeyboardFlags() == {kkfDisambiguate, kkfReportAlternates,
                                     kkfReportAllKeys}  # 13
  s.feed("\x1b[<u")
  doAssert s.kittyKeyboardFlags() == {}

  echo "test_kitty_keyboard bounded depth OK"

block:
  ## The main and alternate screens keep independent stacks -- the
  ## sequence a full-screen TUI emits on entry and exit.
  var s = newScreen(2, 40)
  s.feed("\x1b[>2u")
  doAssert s.kittyKeyboardFlags() == {kkfReportEvents}

  s.feed("\x1b[?1049h\x1b[>1u")
  doAssert s.altScreenActive()
  doAssert s.kittyKeyboardFlags() == {kkfDisambiguate}

  s.feed("\x1b[<u")
  doAssert s.kittyKeyboardFlags() == {}

  # Pops on the alternate screen leave the main stack alone.
  s.feed("\x1b[<9u")
  s.feed("\x1b[?1049l")
  doAssert not s.altScreenActive()
  doAssert s.kittyKeyboardFlags() == {kkfReportEvents}

  # The alternate stack survives a round trip through the main screen.
  s.feed("\x1b[?1047h\x1b[>4u\x1b[?1047l")
  doAssert s.kittyKeyboardFlags() == {kkfReportEvents}
  s.feed("\x1b[?1047h")
  doAssert s.kittyKeyboardFlags() == {kkfReportAlternates}

  echo "test_kitty_keyboard alt screen OK"
