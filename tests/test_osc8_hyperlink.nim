## test_osc8_hyperlink.nim -- OSC 8 hyperlink registration AND per-cell
## hyperlink_id attribution.
##
## Spec ref: =\x1b]8;;https://example.com\x1b\\Click\x1b]8;;\x1b\\= -- the
## "Click" cells should reference the URL via Cell.hyperlinkId; cells
## outside the link must have hyperlinkId == 0.

import std/[options, unicode]
import nim_libvterm

block:
  var s = newScreen(2, 40)
  let url = "https://example.com"

  # OSC 8 ; ; URL ST  Click  OSC 8 ; ; ST
  s.feed("\x1b]8;;" & url & "\x1b\\Click\x1b]8;;\x1b\\")

  # Registry has the URL.
  let all = s.hyperlinks()
  doAssert all.len >= 1, "no hyperlink registered"
  var found = false
  var theId = HyperlinkId(0)
  for h in all:
    if h.uri == url:
      found = true
      theId = HyperlinkId(h.id)
      break
  doAssert found, "URL not found in registry: " & $all
  doAssert uint32(theId) != 0

  # Cells over "Click" should be glyph-positioned.
  doAssert s.cellAt(0, 0).rune == Rune(uint32('C'))
  doAssert s.cellAt(0, 4).rune == Rune(uint32('k'))

  # All five "Click" cells must carry hyperlinkId == theId.
  for c in 0 .. 4:
    let cell = s.cellAt(0, c)
    doAssert cell.hyperlinkId == theId,
      "cell (0," & $c & ") missing hyperlinkId, got " & $cell.hyperlinkId

  # The hyperlinkAt(row, col) accessor returns the registered Hyperlink.
  let opt = s.hyperlinkAt(0, 2)
  doAssert opt.isSome
  doAssert opt.get.uri == url

  # Feed text after the closing OSC 8: those cells must NOT have a hyperlink.
  s.feed(" tail")
  doAssert s.cellAt(0, 6).rune == Rune(uint32('t'))
  for c in 5 .. 10:
    let cell = s.cellAt(0, c)
    doAssert cell.hyperlinkId == HyperlinkId(0),
      "cell (0," & $c & ") should have no hyperlink, got " & $cell.hyperlinkId

  echo "test_osc8_hyperlink OK"
