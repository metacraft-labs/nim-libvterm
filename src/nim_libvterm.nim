## nim_libvterm -- libvterm bindings + Screen API + extended-state overlay.
##
## Public entry point. Re-exports `screen` (which itself re-exports the
## extended-state overlay value types).
##
## Quick example:
##
## ```nim
## import nim_libvterm
##
## var s = newScreen(24, 80)
## s.feed("hello\n")
## echo s.contents()        # "hello"
## echo s.cellAt(0, 0).rune # Rune(104) -- 'h'
## echo s.cursorPosition()  # (1, 0)
## # `s` is destroyed here -- vterm_free runs in `=destroy`.
## ```
##
## The full design is in
## `Front-Ends/IsoNim/isonim-tui.milestones.org` (sections "L2: nim-libvterm"
## and "Memory-safety + testing-rigor charter") in the codetracer-specs repo.

import nim_libvterm/screen
export screen
