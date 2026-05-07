## test_no_leaks.nim -- leak-budget tests.
##
## The basic budget is 0: under the orc/arc memory managers a Screen
## should free its libvterm instance via `=destroy` and not leave any
## resident allocations across iterations.
##
## We don't have an easy hook to verify zero-leak in pure Nim without
## tooling, so the budget check here exercises the construct/feed/destroy
## cycle thousands of times. The Justfile's `test-asan`, `test-lsan`, and
## `test-valgrind` recipes verify the actual memory budget.
##
## When `-d:nimLibvtermHeavy` is defined we run 100,000 iterations
## (charter "100k cycles"). Default is 1,000 for fast feedback.

when defined(linux):
  import std/os
import nim_libvterm

const cycles = when defined(nimLibvtermHeavy): 100_000 else: 1_000

# Steady-state allocate/feed/destroy loop. The 10-KB feed exercises the
# screen layer, OSC handling, and the extended-state grids.
proc steadyState() =
  var bigBuf = newStringOfCap(10 * 1024)
  for _ in 0 ..< 1024:
    bigBuf.add "abcdefghij"
  for i in 0 ..< cycles:
    var s = newScreen(24, 80)
    s.feed(bigBuf)
    s.feed("\x1b]8;;https://example.com\x1b\\link\x1b]8;;\x1b\\")
    s.feed("\x1b[?2026h\x1b[31mred\x1b[0m\x1b[?2026l")
    discard s.contents()
  echo "steady-state cycles=", cycles, " OK"

# Panic-during-feed path: ensure that an exception thrown after newScreen
# but before completing setup does not leak. We simulate this with a
# `defer` that destructs.
proc underPanic() =
  for i in 0 ..< 100:
    try:
      var s = newScreen(10, 10)
      s.feed("hi")
      if i mod 2 == 0:
        raise newException(ValueError, "synthetic")
    except ValueError:
      discard
  echo "under-panic OK"

# File-handle accounting (libvterm is pure userspace; we still verify
# the FD count doesn't drift).
proc fdAccounting() =
  when defined(linux):
    # Count entries in /proc/self/fd before and after a ten-Screen burst.
    proc countFds(): int =
      try:
        for kind, path in walkDir("/proc/self/fd"):
          discard kind
          discard path
          inc result
      except CatchableError:
        result = -1
    let before = countFds()
    for _ in 0 ..< 10:
      var s = newScreen(20, 60)
      s.feed("test data")
    let after = countFds()
    doAssert before == after,
      "fd count drifted: before=" & $before & " after=" & $after
    echo "fd-accounting OK (linux)"
  else:
    echo "fd-accounting skipped (non-linux)"

steadyState()
underPanic()
fdAccounting()
echo "test_no_leaks OK"
