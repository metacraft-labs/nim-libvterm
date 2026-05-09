## test_sgr_underline_color.nim -- modern colored-underline SGR
## sub-parameter parsing through real-byte feed paths.
##
## CSI 58 sets a per-cell underline color (separate from foreground);
## CSI 59 resets it. Modern emitters (linters, spell-checkers, the
## VS Code-style editors) rely on this to draw severity-tinted squiggles.
##
## Coverage:
##   * `CSI 58:2::R:G:B m`   -- truecolor underline (empty colorspace).
##   * `CSI 58:2:0:R:G:B m`  -- truecolor underline (explicit colorspace 0).
##   * `CSI 58:5:N m`        -- 256-color indexed underline.
##   * `CSI 58:2::R:G:B m foo CSI 59 m bar` -- colour-then-reset.
##   * `CSI 4:3 m CSI 58:2::R:G:B m` -- curly + color independent.
##   * `CSI 4:4 m CSI 58:2::R:G:B m` -- dotted + color independent.
##
## Each block feeds a real byte sequence through `Screen.feed` and
## inspects the resulting `Cell.underlineColor` and `Cell.underline`.
## No mocks; no shortcuts.

import std/unicode
import nim_libvterm

block truecolor_red:
  ## CSI 58:2::255:0:0 m  -- underline color = bright red, empty colorspace.
  var s = newScreen(2, 40)
  s.feed("\x1b[58:2::255:0:0mtext")
  for col in 0 .. 3:
    let c = s.cellAt(0, col)
    doAssert c.underlineColor.kind == ckRgb,
      "col=" & $col & " kind=" & $c.underlineColor.kind
    doAssert c.underlineColor.r == 255'u8 and
             c.underlineColor.g == 0'u8 and
             c.underlineColor.b == 0'u8,
      "col=" & $col & " rgb=(" & $c.underlineColor.r & "," &
        $c.underlineColor.g & "," & $c.underlineColor.b & ")"

block truecolor_explicit_colorspace:
  ## CSI 58:2:0:255:128:64 m  -- explicit colorspace token (0 = sRGB).
  ## The parser must tolerate this layout in addition to the empty-slot
  ## form, ignoring the colorspace value either way.
  var s = newScreen(2, 40)
  s.feed("\x1b[58:2:0:255:128:64mABC")
  let runes = ['A', 'B', 'C']
  for i, ch in runes:
    let c = s.cellAt(0, i)
    doAssert c.rune == Rune(uint32(ch))
    doAssert c.underlineColor.kind == ckRgb,
      "i=" & $i & " kind=" & $c.underlineColor.kind
    doAssert c.underlineColor.r == 255'u8 and
             c.underlineColor.g == 128'u8 and
             c.underlineColor.b == 64'u8,
      "i=" & $i & " rgb=(" & $c.underlineColor.r & "," &
        $c.underlineColor.g & "," & $c.underlineColor.b & ")"

block indexed_palette:
  ## CSI 58:5:9 m  -- 256-color palette index 9 (bright red in the
  ## standard ANSI palette). We don't resolve the palette to RGB --
  ## consumers do that at render time -- so the assertion is on the
  ## stored idx itself.
  var s = newScreen(2, 40)
  s.feed("\x1b[58:5:9mxyz")
  for col in 0 .. 2:
    let c = s.cellAt(0, col)
    doAssert c.underlineColor.kind == ckIndexed,
      "col=" & $col & " kind=" & $c.underlineColor.kind
    doAssert c.underlineColor.idx == 9'u8,
      "col=" & $col & " idx=" & $c.underlineColor.idx

block reset_via_csi_59:
  ## CSI 58:2::0:0:255 m foo CSI 59 m bar
  ## `foo` is blue-underlined; `bar` is back to default (foreground).
  var s = newScreen(2, 40)
  s.feed("\x1b[58:2::0:0:255mfoo\x1b[59mbar")
  for col in 0 .. 2:  # foo
    let c = s.cellAt(0, col)
    doAssert c.underlineColor.kind == ckRgb,
      "foo col=" & $col & " kind=" & $c.underlineColor.kind
    doAssert c.underlineColor.b == 255'u8 and
             c.underlineColor.r == 0'u8 and
             c.underlineColor.g == 0'u8,
      "foo col=" & $col
  for col in 3 .. 5:  # bar
    let c = s.cellAt(0, col)
    doAssert c.underlineColor.kind == ckDefault,
      "bar col=" & $col & " kind=" & $c.underlineColor.kind
    doAssert c.underlineColor == colDefault,
      "bar col=" & $col & " expected colDefault"

block curly_plus_color:
  ## Style and color are independent dimensions: `CSI 4:3 m` selects
  ## curly underline, `CSI 58:2::255:255:0 m` colours it yellow. Both
  ## attributes must coexist on every cell of the run.
  var s = newScreen(2, 40)
  s.feed("\x1b[4:3m\x1b[58:2::255:255:0mtext")
  for col in 0 .. 3:
    let c = s.cellAt(0, col)
    doAssert c.underline == usCurly,
      "col=" & $col & " underline=" & $c.underline
    doAssert c.underlineColor.kind == ckRgb,
      "col=" & $col & " color.kind=" & $c.underlineColor.kind
    doAssert c.underlineColor.r == 255'u8 and
             c.underlineColor.g == 255'u8 and
             c.underlineColor.b == 0'u8,
      "col=" & $col & " yellow rgb=(" & $c.underlineColor.r & "," &
        $c.underlineColor.g & "," & $c.underlineColor.b & ")"

block dotted_plus_color:
  ## Combined with the extended-underline grid: dotted + grey.
  ## This exercises both the underline-style chunked walker (4:4 ->
  ## extUnderline=usDotted, mirrored to underline) AND the underline-
  ## color chunked walker on the same cells.
  var s = newScreen(2, 40)
  s.feed("\x1b[4:4m\x1b[58:2::128:128:128mtext")
  for col in 0 .. 3:
    let c = s.cellAt(0, col)
    doAssert c.extUnderline == usDotted,
      "col=" & $col & " ext=" & $c.extUnderline
    doAssert c.underline == usDotted,
      "col=" & $col & " underline=" & $c.underline
    doAssert c.underlineColor.kind == ckRgb,
      "col=" & $col & " color.kind=" & $c.underlineColor.kind
    doAssert c.underlineColor.r == 128'u8 and
             c.underlineColor.g == 128'u8 and
             c.underlineColor.b == 128'u8,
      "col=" & $col & " grey rgb=(" & $c.underlineColor.r & "," &
        $c.underlineColor.g & "," & $c.underlineColor.b & ")"

block plain_then_colored_then_plain:
  ## A colored-underline run sandwiched between plain text -- ensures
  ## the chunked walker only stamps the colored cells, nothing leaks
  ## into the surrounding plain runs.
  var s = newScreen(2, 40)
  s.feed("plain\x1b[58:2::10:20:30mMID\x1b[59mtail")
  for col in 0 .. 4:  # plain
    let c = s.cellAt(0, col)
    doAssert c.underlineColor.kind == ckDefault,
      "plain col=" & $col & " kind=" & $c.underlineColor.kind
  for col in 5 .. 7:  # MID
    let c = s.cellAt(0, col)
    doAssert c.underlineColor.kind == ckRgb,
      "MID col=" & $col & " kind=" & $c.underlineColor.kind
    doAssert c.underlineColor.r == 10'u8 and
             c.underlineColor.g == 20'u8 and
             c.underlineColor.b == 30'u8,
      "MID col=" & $col
  for col in 8 .. 11:  # tail
    let c = s.cellAt(0, col)
    doAssert c.underlineColor.kind == ckDefault,
      "tail col=" & $col & " kind=" & $c.underlineColor.kind

block sgr_zero_resets_color:
  ## A bare SGR 0 reset must clear the underline-color pen too.
  ## (Same rule as `extUnderlinePen`.)
  var s = newScreen(2, 40)
  s.feed("\x1b[58:2::200:100:50mA\x1b[0mB")
  let a = s.cellAt(0, 0)
  let b = s.cellAt(0, 1)
  doAssert a.underlineColor.kind == ckRgb,
    "A: " & $a.underlineColor.kind
  doAssert b.underlineColor.kind == ckDefault,
    "B (after reset): " & $b.underlineColor.kind

echo "test_sgr_underline_color OK"
