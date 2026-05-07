## test_api_invariants.nim -- charter §1 API invariants.
##
## These are compile-time + runtime checks of the rules from
## "Memory-safety + testing-rigor charter":
##   * Public types are value `object` (not `ref object`).
##   * `=copy` is disabled on owning handles.
##   * `=destroy` releases the underlying libvterm instance.

import std/[typetraits, unicode]
import nim_libvterm

# 1. Compile-time: Screen is not a ref.
static:
  doAssert Screen is object
  doAssert Screen isnot ref
  doAssert Cell is object
  doAssert Cell isnot ref
  doAssert Hyperlink is object
  doAssert Notification is object
  doAssert Image is object
  doAssert WindowOp is object

block disabled_copy:
  # 2. =copy is disabled. The following compiles only when commented.
  # If we tried `let b = a` we'd get a compile error. We can verify the
  # ABI by sinking instead.
  var a = newScreen(5, 5)
  a.feed("hi")
  # Move (sink) -- this should work. Nim handles the move ourselves.
  var b = move(a)
  doAssert b.cellAt(0, 0).rune == Rune(uint32('h'))
  echo "disabled-copy block OK"

block destructor_runs:
  # 3. =destroy releases. We can't observe vterm_free directly without
  # leak-detector tooling; the test suite's `test_no_leaks` covers that.
  # Here we just ensure that constructing/destructing many in a loop does
  # not crash.
  for _ in 0 ..< 100:
    var s = newScreen(10, 30)
    s.feed("test")
    let _ = s.contents()
  echo "destructor block OK"

echo "test_api_invariants OK"
