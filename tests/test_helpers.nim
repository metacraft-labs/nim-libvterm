## tests/test_helpers.nim -- shared utilities for the test suite.
##
## NB: this file does NOT begin with `test_` so the Justfile's recipe
## list won't pick it up as a runnable test. Tests `import` this module
## with `import ./test_helpers` style relative paths.

import std/[strutils, unicode]
import nim_libvterm

template feedAll*(s: var Screen; bytes: openArray[string]) =
  ## Feed each fragment in turn -- handy for verifying that fragmented
  ## OSCs are reassembled correctly.
  for b in bytes:
    s.feed(b)

proc rowAsString*(s: Screen; row: int): string =
  ## Return the visible rune contents of one row, with trailing blanks
  ## trimmed.
  let n = s.size().cols
  result = newStringOfCap(n)
  for c in 0 ..< n:
    let r = s.cellAt(row, c).rune
    if uint32(r) == 0'u32:
      result.add ' '
    else:
      var buf: string
      buf.add r
      result.add buf
  result = result.strip(leading = false, trailing = true)

proc esc*(s: string): string =
  ## Replace `\\x1b` and `\\x07` shorthand with the actual control bytes.
  result = newStringOfCap(s.len)
  var i = 0
  while i < s.len:
    if i + 3 < s.len and s[i] == '\\' and s[i + 1] == 'x':
      let hex = s[i + 2 .. i + 3]
      result.add char(parseHexInt(hex))
      i += 4
    elif i + 1 < s.len and s[i] == '\\' and s[i + 1] == 'e':
      result.add '\x1b'
      i += 2
    else:
      result.add s[i]
      i += 1
