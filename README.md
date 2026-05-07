# nim-libvterm

Nim bindings to [libvterm](https://github.com/neovim/libvterm) + a
value-typed `Screen` API + an extended-state overlay for modern
terminal protocols (OSC 8 hyperlinks, OSC 7 CWD, OSC 9/99 notifications,
DEC mode 2026 synchronized output, Kitty keyboard protocol,
modify-other-keys, mouse 1006/1015/1016, image registries).

MIT-licensed (matches libvterm).

## Quick start

```nim
import nim_libvterm

var s = newScreen(24, 80)
s.feed("hello\n")
echo s.contents()                  # "hello"
echo s.cursorPosition()            # (1, 0)

s.feed("\x1b]2;My Title\x1b\\")   # OSC 2 -- set window title
echo s.title()                     # "My Title"

s.feed("\x1b]8;;https://example.com\x1b\\Click\x1b]8;;\x1b\\")
echo s.hyperlinks()                # @[Hyperlink(uri: "https://example.com", ...)]

# `s` is destroyed at end of scope -- vterm_free runs in `=destroy`.
```

## Status

L2 milestone (nim-libvterm) -- core complete; image pixel decoders
deferred. See `Front-Ends/IsoNim/isonim-tui.milestones.org` in the
codetracer-specs repo.

## Build + test

```sh
just build       # compile every test
just test        # run the default matrix point
just lint        # nim check + nixfmt --check
```

The full charter test matrix (memory managers x compile modes x
threading x sanitizers + valgrind) runs in CI on every PR.

See [AGENTS.md](AGENTS.md) for the full architectural rationale and
contributor guide.
