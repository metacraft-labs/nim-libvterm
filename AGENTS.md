# nim-libvterm

Nim bindings to libvterm + a value-typed `Screen` API + an extended-state
overlay for modern terminal protocols (OSC 8 hyperlinks, OSC 7 CWD, OSC
9/99 notifications, DEC mode 2026 synchronized output, Kitty keyboard
protocol, modify-other-keys, mouse 1006/1015/1016, image registries).

## What this library does

`nim-libvterm` parses raw terminal byte streams (the kind a PTY child
produces -- typically obtained from `nim-pty`) and exposes the resulting
screen state as a queryable cell grid plus a bag of pull-style getters:

- `feed(bytes)` -- feed bytes to the parser
- `cellAt(row, col)` -- inspect one cell (rune, fg, bg, attrs, hyperlink, ...)
- `contents()` / `region(...)` -- bulk-extract text
- `cursorPosition()`, `cursorShape()`, `cursorVisible()`, ...
- `title()`, `iconName()`, `workingDirectory()`, ...
- `hyperlinks()`, `hyperlinkAt(row, col)`
- `notifications()`, `synchronizedOutput()`, `mouseProtocol()`,
  `kittyKeyboardFlags()`, `modifyOtherKeys()`, `windowOps()`
- `images()`, `imageAt(row, col)`, `imageData(ref)` (registry-only;
  pixel decoders are deferred -- see `Front-Ends/IsoNim/isonim-tui.milestones.org`
  L2 deferred bullets)

The library is layered:

```
+------------------------------------+
| Nim wrapper (Screen + Extended)    |
|  - parser-layer pre-scan           |
|  - state-fallback OSC capture      |
|  - settermprop push -> pull mirror |
+--------+---------------------------+
         |
+--------v---------------------------+
| libvterm (C, MIT, vendored)        |
+------------------------------------+
```

## Commands

```sh
just build           # compile every test as a smoke check
just test            # run the default matrix point (orc + release + threads:on)
just lint            # nim check + nixfmt --check
just format          # nimpretty + nixfmt
```

Charter matrix recipes (CI runs each as a separate matrix cell):

```sh
just test-arc        # arc memory manager, all three modes
just test-orc        # orc memory manager, all three modes
just test-refc       # refc memory manager, all three modes
just test-threads-off
just test-asan       # AddressSanitizer (Linux/clang)
just test-ubsan      # UndefinedBehaviorSanitizer
just test-tsan       # ThreadSanitizer
just test-lsan       # LeakSanitizer
just test-valgrind   # secondary leak verification
just test-leaks-heavy  # 100k-cycle leak budgets (slow; CI only)
just test-all        # everything that runs on a Linux runner
```

## Project structure

```
src/
  nim_libvterm.nim                # public top-level -- re-exports screen
  nim_libvterm/ffi.nim            # raw FFI to vendored libvterm
  nim_libvterm/screen.nim         # public Screen API (value-typed)
  nim_libvterm/extended_state.nim # OSC/CSI overlay for protocols libvterm misses
  nim_libvterm/c/nim_shim.c       # tiny C helpers for libvterm bit-fields
vendor/
  libvterm/                       # vendored neovim/libvterm fork (MIT)
    PINNED_REVISION               # git SHA pinned for hermetic builds
tests/
  test_libvterm_*.nim             # libvterm-coverage tests
  test_osc7_cwd.nim               # OSC 7
  test_osc8_hyperlink.nim         # OSC 8
  test_osc9_notification.nim      # OSC 9 + 99
  test_dec_2026_synchronized_output.nim
  test_csi_t_window_ops.nim
  test_kitty_keyboard.nim
  test_modify_other_keys.nim
  test_mouse_protocol.nim
  test_state_mirror_pull_after_push.nim
  test_image_registry.nim         # image-protocol registry framework
  test_api_invariants.nim         # charter §1 API rules
  test_gc_traced_inner_block.nim  # inner block must stay GC-reachable
  test_no_leaks.nim               # leak-budget suite
.github/workflows/ci.yml          # full charter matrix on every PR
flake.nix                         # nix devShell + checks
Justfile                          # all build/test/lint recipes
nim_libvterm.nimble               # single-source-of-truth version
```

## Architectural decisions

- **libvterm is vendored, not a system dependency.** Hermetic builds; we
  control the version. The neovim fork is the canonical live branch
  (upstream at leonerd.org.uk is dormant). See
  `vendor/libvterm/PINNED_REVISION` for the exact git SHA.

- **Bit-field structs go through a C shim.** Nim cannot portably express
  C bit-fields like `unsigned int bold : 1;`. We expose every bit-field
  field via a tiny `nim_shim.c` getter. This keeps `cast` out of the
  public API and makes the FFI layout robust across compilers.

- **No `ref object` in the public API.** `Screen`, `Cell`, `Hyperlink`,
  `Notification`, `Image`, `WindowOp` are value `object`s. `=copy` is
  disabled on `Screen`; `=destroy` calls `vterm_free`. Charter §1.

- **Heap-pinned inner struct, allocated with `new`.** `Screen` holds
  `inner: ref ScreenInner`. The inner struct embeds the libvterm handle,
  the extended-state overlay, and the callback-struct storage. It's
  heap-allocated once at construction and its address (`addr inner[]`,
  stable for the block's life) is what libvterm gets as its `user` word;
  the callback thunks `cast` it back to `ptr ScreenInner`.

  The allocation **must** be traced (`new`), not raw (`alloc0`).
  `ExtendedState` embeds `seq`s, `string`s and `Table`s; under
  `--mm:refc` the collector only keeps those alive when the memory
  holding the reference is itself part of the heap graph. `alloc0`
  memory is not, so the grids were swept while the `rows`/`cols`
  integers beside them stayed valid, and `cellAt` indexed freed memory
  (`IndexDefect`). arc/orc do not trace and never saw it. Regression
  test: `tests/test_gc_traced_inner_block.nim`.

  Consequence: release is arranged differently per memory manager, and
  the reason is spelled out at the `when defined(gcDestructors)` block
  in `screen.nim`. arc/orc give `Screen` *no* hand-written `=destroy`
  (one would suppress destruction of its own fields and strand the
  block); the libvterm instance is freed by the `OwnedVTerm` RAII
  wrapper inside `ScreenInner`. refc keeps `=destroy(var Screen)`,
  because its collector never runs `=destroy` hooks on the objects it
  sweeps, and lets the GC reclaim everything else.

- **Extended-state coverage uses two complementary paths.**

  1. **Byte-stream pre-scan** (in `feed()`) catches DEC private modes
     that libvterm's `set_dec_mode` consumes silently without invoking
     any callback (DEC mode 2026, 1016, 1006, 1015, 1005) and
     leader-bytes that libvterm's `on_csi` rejects at the sanity check
     (Kitty keyboard `CSI = N u`, `< N u`).
  2. **State-layer OSC fallback** (`vterm_state_set_unrecognised_fallbacks`)
     receives every OSC libvterm doesn't itself handle (OSC 7, 8, 9, 99,
     1337, ...).

  We deliberately do NOT install parser-layer callbacks (which would
  unhook libvterm's state machine entirely and force us to re-implement
  state-layer dispatch from scratch).

- **Image protocols are observed at registry granularity.** Sixel,
  Kitty graphics, and iTerm2 OSC 1337 sightings allocate an `ImageRef`
  and record placement. Pixel decoders are deferred (large; ~1.2 KLOC
  combined). The public API surface (`images()`, `imageAt(row, col)`,
  `imageData(ref)`) is in place; `Image.pixels` is empty until the
  decoders land.

- **Per-cell hyperlink mapping is approximate.** OSC 8 hyperlinks are
  registered globally; the cell-grid lookup currently returns the
  active hyperlink for any cell whose row falls within the OSC 8 active
  range. Per-cell precision (tracked via state-layer `putglyph`)
  is the next-iteration deliverable.

## Coding conventions

- `--styleCheck:usages --styleCheck:error` is enforced -- use `camelCase`
  identifiers. The Justfile bakes this into every nim invocation.
- Public types are value `object`s. `ref object` is forbidden in the
  public API (charter §1).
- Public APIs never expose raw `ptr`. Use `openArray[T]`, `seq[byte]`,
  `string`, or typed handles (`HyperlinkId`, `ImageRef` -- both
  `distinct uint32`).
- `cast` is forbidden in the public API; it appears at exactly three
  sites in `screen.nim`, all at the FFI boundary and all commented
  inline: (1) `innerOf` recovers the Nim self-pointer from libvterm's
  `user` callback argument, (2) `feed` adapts `openArray[byte]` to a
  `cstring` for `vterm_input_write`, and (3) `region` exposes a Nim
  `string` buffer to `vterm_screen_get_text`. Each use is justified
  inline. (A fourth site -- narrowing `alloc0`'s `pointer` to
  `ptr ScreenInner` -- went away when the inner block became a traced
  `ref` allocation.)
- Every test is a real-stack integration test -- no mocks. Tests feed
  real byte streams to the real libvterm via FFI and assert on the
  real `Screen` state.

## Specs

The authoritative specifications for this library live in the
`codetracer-specs` repo:

- `Front-Ends/IsoNim/isonim-tui.milestones.org` -- see "L2: nim-libvterm"
  and the "Memory-safety + testing-rigor charter".

When user requests change the public API, update the spec in the same
change set.
