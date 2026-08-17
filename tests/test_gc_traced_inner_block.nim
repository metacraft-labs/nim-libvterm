## test_gc_traced_inner_block.nim -- the `ScreenInner` block must stay
## reachable for a tracing collector.
##
## Regression test for a use-after-free that only `--mm:refc` could see.
## `ScreenInner` used to be `alloc0` memory, i.e. outside the Nim heap
## graph. Everything GC-managed that it embeds -- and `ExtendedState`
## alone embeds eight `seq`s, two `Table`s and eight `string`s -- was
## therefore an unreachable root. refc's mark phase swept those buffers
## while the plain-`int` `rows`/`cols` sitting next to them stayed valid,
## so the next `cellAt` indexed freed memory with coordinates that still
## looked in range:
##
##     src/nim_libvterm/screen.nim(597) cellAt
##     src/nim_libvterm/extended_state.nim(820) extUnderlineCellAt
##     Unhandled exception: index 1743 not in 0 .. 15 [IndexDefect]
##
## arc/orc never trace, so they never noticed; the failure was refc-only
## in debug *and* release. What made it invisible to the rest of this
## suite is that every other test finishes before refc's heuristics run a
## collection at all. This test forces the issue: it drives a collection
## and then churns enough allocations to reuse whatever was freed, so a
## dangling buffer shows up as corrupt data rather than as memory that
## merely happens to still be readable.
##
## No mocks: a real `Screen` over the real vendored libvterm, fed real
## byte streams. The only artificial element is the explicit
## `GC_fullCollect` -- without it the test would depend on allocator
## heuristics and would be flaky in the safe direction (silent pass).

import std/[options, strutils]
import nim_libvterm

const
  rows = 24
  cols = 80
  url = "https://example.com/traced"

proc collectAndChurn() =
  ## Force a collection, then allocate hard enough that anything freed is
  ## handed out again. Under arc/orc `GC_fullCollect` is a no-op, which is
  ## fine -- the churn still exercises the allocator.
  when declared(GC_fullCollect):
    GC_fullCollect()
  var junk: seq[string] = @[]
  for i in 0 ..< 20_000:
    junk.add repeat('x', 1 + (i mod 96))
  junk = @[]
  when declared(GC_fullCollect):
    GC_fullCollect()

proc checkEverything(s: Screen; phase: string) =
  ## Every extended-state field that lives inside the inner block, read
  ## back through the public API.

  # Per-cell grids -- `seq[uint8]` / `seq[uint32]` inside ExtendedState.
  # These are what actually blew up; walk the whole grid, not one cell.
  for r in 0 ..< rows:
    for c in 0 ..< cols:
      discard s.cellAt(r, c)

  # The dotted-underline run is stamped into extUnderlineGrid.
  doAssert s.cellAt(0, 0).extUnderline == usDotted,
    phase & ": lost extUnderline grid contents"
  doAssert s.cellAt(0, 0).underlineColor == Color(kind: ckRgb, r: 1, g: 2, b: 3),
    phase & ": lost extUnderlineColor grid contents"

  # Hyperlink table (`Table[uint32, Hyperlink]`) + hyperGrid (`seq[uint32]`).
  let links = s.hyperlinks()
  doAssert links.len >= 1, phase & ": hyperlink registry emptied"
  var seen = false
  for h in links:
    if h.uri == url: seen = true
  doAssert seen, phase & ": hyperlink URI lost -> " & $links
  let at = s.hyperlinkAt(1, 1)
  doAssert at.isSome, phase & ": per-cell hyperlink mapping lost"
  doAssert at.get.uri == url, phase & ": per-cell hyperlink URI lost"

  # Notification list (`seq[Notification]`, each holding three strings).
  let notes = s.notifications()
  doAssert notes.len >= 1, phase & ": notification list emptied"
  doAssert notes[0].body == "ping", phase & ": notification body lost"

  # OSC 7 working directory (`string`).
  doAssert s.workingDirectory() == "/tmp/traced", phase & ": cwd lost"

  # Window-op log (`seq[WindowOp]`, each holding a `seq[int]`).
  let ops = s.windowOps()
  doAssert ops.len >= 1, phase & ": window-op log emptied"
  doAssert ops[0].args.len >= 2, phase & ": window-op args lost"

  # Image registry (`Table[uint32, Image]`, values hold pixel `seq[byte]`).
  let imgs = s.images()
  doAssert imgs.len >= 1, phase & ": image registry emptied"
  let img = s.imageData(imgs[0])
  doAssert img.width > 0 and img.height > 0, phase & ": image dimensions lost"

  # Push-mirror strings that live in ScreenInner itself.
  doAssert s.title() == "traced-title", phase & ": title lost"

  # Cell text is libvterm-owned, but read it back too -- a corrupt inner
  # block would just as happily have corrupted `vt`.
  doAssert s.contents().contains("ab"), phase & ": screen text lost"

proc populate(s: var Screen) =
  s.feed("\x1b]0;traced-title\x1b\\")
  s.feed("\x1b]7;file:///tmp/traced\x1b\\")
  s.feed("\x1b]9;ping\x1b\\")
  # Dotted + RGB underline pen, then text: stamps both ext grids.
  s.feed("\x1b[4:4m\x1b[58:2::1:2:3mab\x1b[59m\x1b[4:0m")
  s.feed("\r\n\x1b]8;;" & url & "\x1b\\link\x1b]8;;\x1b\\")
  s.feed("\x1b[8;24;80t")                       # window op with args
  # A 2x2 Kitty RGBA image -- registers an entry in the image table.
  s.feed("\x1b_Gf=32,s=2,v=2,a=T;" &
         "//////8AAP//AAD//wAAAP//AAA=" & "\x1b\\")

proc main() =
  # 1. A live Screen must survive a collection cycle.
  var s = newScreen(rows, cols)
  populate(s)
  checkEverything(s, "fresh")
  collectAndChurn()
  checkEverything(s, "after one collect")
  collectAndChurn()
  collectAndChurn()
  checkEverything(s, "after repeated collects")

  # 2. A resize reallocates every grid; they must survive too.
  s.resize(rows * 2, cols)
  s.feed("\x1b[4:4m\x1b[58:2::1:2:3mZ\x1b[59m\x1b[4:0m")
  collectAndChurn()
  for r in 0 ..< rows * 2:
    for c in 0 ..< cols:
      discard s.cellAt(r, c)
  doAssert s.size() == (rows * 2, cols)

  # 3. Several Screens alive at once across collections -- catches an
  #    inner block that is reachable only by accident (e.g. via a stale
  #    register or the most recent allocation).
  var many: seq[Screen] = @[]
  for i in 0 ..< 8:
    var t = newScreen(rows, cols)
    populate(t)
    many.add(move(t))
  collectAndChurn()
  for i in 0 ..< many.len:
    checkEverything(many[i], "multi-screen #" & $i)

  echo "test_gc_traced_inner_block OK"

main()
