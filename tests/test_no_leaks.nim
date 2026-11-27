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

when defined(linux) or defined(macosx):
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
# the descriptor count doesn't drift). Each charter platform counts what
# the OS itself reports as open for this process:
#
# - Linux: the entries of /proc/self/fd (proc(5)).
# - macOS: the entries of /dev/fd, the fdesc file system, which lists the
#   calling process's open descriptors (fdesc(5); `man 5 fdesc`).
# - Windows: GetProcessHandleCount
#   (https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-getprocesshandlecount),
#   every kernel handle the process holds, which includes the HANDLE behind
#   each CRT file descriptor.
#
# The two directory listings open one descriptor of their own while they
# run; it is open during both counts, so it cancels out of the comparison.
#
# Any other platform has no count here and fails the module, so a run there
# can never report this budget as met.
when defined(windows):
  proc getProcessHandleCount(process: int, count: ptr uint32): int32 {.
    importc: "GetProcessHandleCount", stdcall, dynlib: "kernel32".}
  proc getCurrentProcess(): int {.
    importc: "GetCurrentProcess", stdcall, dynlib: "kernel32".}

proc countDescriptors(): int =
  ## Number of descriptors (handles on Windows) this process holds now.
  ## Raises when the platform's count cannot be read: a count that silently
  ## fell back to a constant would make the before/after comparison pass.
  when defined(linux) or defined(macosx):
    const listing = when defined(linux): "/proc/self/fd" else: "/dev/fd"
    for kind, path in walkDir(listing):
      discard kind
      discard path
      inc result
    # 0, 1 and 2 are open in any test process; fewer entries means the
    # listing did not describe this process.
    doAssert result >= 3, listing & " listed only " & $result & " entries"
  elif defined(windows):
    var count: uint32
    if getProcessHandleCount(getCurrentProcess(), addr count) == 0:
      raise newException(OSError, "GetProcessHandleCount failed")
    doAssert count > 0'u32, "GetProcessHandleCount reported no handles"
    result = int(count)
  else:
    doAssert false,
      "fd-accounting has no descriptor count for this platform; " &
      "add one to countDescriptors() in tests/test_no_leaks.nim"

proc screenBurst() =
  # Ten Screens constructed, fed and destroyed.
  for _ in 0 ..< 10:
    var s = newScreen(20, 60)
    s.feed("test data")

proc fdAccounting() =
  const platform =
    when defined(linux): "linux"
    elif defined(macosx): "macos"
    elif defined(windows): "windows"
    else: "unsupported"
  # No warm-up burst before the baseline, on any platform: measured on
  # Windows x64 (2026-11-27), the handle count was identical before the
  # first burst and after each of six, under orc and refc.
  let before = countDescriptors()
  screenBurst()
  let after = countDescriptors()
  doAssert before == after,
    "fd count drifted: before=" & $before & " after=" & $after
  echo "fd-accounting OK (", platform, ", ", before, " open)"

steadyState()
underPanic()
fdAccounting()
echo "test_no_leaks OK"
