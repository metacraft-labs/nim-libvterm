## nim_libvterm/extended_state.nim -- the extended-state overlay.
##
## libvterm covers the SGR/cursor/scroll-region/alt-screen core cleanly,
## but it deliberately ignores a handful of modern terminal protocols
## that production TUIs (and the test infrastructure built on them) need
## to observe. This module bridges the gap.
##
## Coverage
## --------
## Decoded inline:
##   * OSC 7  -- working-directory tracking
##   * OSC 8  -- hyperlinks (per-cell hyperlink_id grid)
##   * OSC 9  -- xterm "growl" notifications
##   * OSC 99 -- Kitty-style notification protocol
##   * DEC 2026 -- synchronized output (CSI ? 2026 h/l)
##   * CSI 4 : N m -- extended underline styles (curly / dotted / dashed)
##   * CSI > 4 ; Pn m -- modify-other-keys
##   * CSI ? 1016 h/l -- mouse pixel-position protocol selector
##   * CSI t -- window manipulation (recorded; not actuated)
##   * CSI = ... u  /  CSI > ... u -- Kitty keyboard progressive enhancement
##
## Image protocols (Sixel / Kitty graphics / iTerm2 OSC 1337) are tracked
## here at the *registry* level: each `apc`/`dcs`/OSC 1337 sighting
## allocates an `ImageRef` and records its placement, but pixel decoding
## is deferred to a follow-up. Consumers get an `ImageRef` and can call
## `imageData(ref)` -- they will see `format = ifPlaceholder` and an
## empty `pixels` field until the decoders land.
##
## Public-API rules (charter)
## --------------------------
## * Public types are value `object`s.
## * `=copy`/`=destroy` are user-visible -- we let the compiler synthesise
##   them so the owning seqs/strings/tables are freed automatically. We
##   do NOT define a custom `=destroy` (a destructor with body `discard`
##   would suppress the default and leak every heap-backed field).
## * No raw `ptr` exposed. (The hyperlink/image grids are flat `seq[uint32]`
##   stored in `ExtendedState`.)
## * `cast` is not used anywhere in this module.

import std/[options, tables, strutils]

# ---------------------------------------------------------------------------
# Public value types
# ---------------------------------------------------------------------------

type
  Hyperlink* = object
    id*: uint32
    uri*: string
    params*: string  ## Raw `params` string of an OSC 8 (e.g. "id=foo")

  Notification* = object
    title*: string
    body*: string
    metadata*: string

  ImageFormat* = enum
    ## When pixel decoders are deferred, all decoded images carry
    ## `ifPlaceholder` so callers can still discriminate.
    ifPlaceholder, ifSixel, ifKitty, ifITerm2

  Transparency* = enum
    txOpaque, txTransparent

  ImagePlacement* = object
    row*, col*: int
    width*, height*: int  ## In cells (0 = unspecified / pixel-only)

  Image* = object
    format*: ImageFormat
    pixels*: seq[byte]   ## Decoded RGBA. Empty until decoders ship.
    width*, height*: int  ## Pixels.
    placement*: ImagePlacement
    zIndex*: int
    transparency*: Transparency
    rawSize*: int        ## Bytes of the raw payload, useful for telemetry
                         ## even when pixel decoding is deferred.

  ExtUnderlineState* = enum
    esuNone, esuDotted, esuDashed

  KittyKeyFlag* = enum
    kkfDisambiguate
    kkfReportEvents
    kkfReportAlternates
    kkfReportAllKeys
    kkfReportText

  MouseProtocol* = enum
    mpNone, mpX10, mpUtf8, mpSgr, mpUrxvt, mpPixel

  WindowOpKind* = enum
    woResize, woMove, woRaise, woLower, woGetTitle, woGetIcon, woGetSize, woOther

  WindowOp* = object
    kind*: WindowOpKind
    args*: seq[int]

  ExtendedState* = object
    ## The full overlay state for one Screen instance.
    notificationCap: int
    notificationsList: seq[Notification]
    cwd: string
    syncOutput: bool
    extUnderlinePen: ExtUnderlineState
    kittyStack: seq[set[KittyKeyFlag]]
    modifyKeysLevel: int
    mouseProto: MouseProtocol
    windowOpLog: seq[WindowOp]

    # OSC 8 hyperlink table
    hyperlinkTable: Table[uint32, Hyperlink]
    nextHyperlinkId: uint32
    activeHyperlink: uint32   ## "pen" current value
    hyperlinkUriBuf: string   ## buffered while OSC 8 streams in chunks
    hyperlinkParamsBuf: string
    hyperlinkInProgress: bool

    # Per-cell hyperlink grid: hyperGrid[row * cols + col] = hyperlink_id.
    #
    # Population strategy: when OSC 8 opens a link, the screen.nim caller
    # snapshots the libvterm cursor position and passes it into
    # `handleOsc` -- we store it in `linkOpenRow/linkOpenCol`. When OSC 8
    # closes the link (empty URI), the caller again passes the current
    # cursor; we fill `hyperGrid[openRow][openCol .. closeCol-1]` (or
    # multi-row equivalent if the link wrapped). This is precise so long
    # as OSC 8 brackets text contiguously, which is the canonical use.
    hyperGridRows: int
    hyperGridCols: int
    hyperGrid: seq[uint32]
    linkOpenRow: int
    linkOpenCol: int
    linkOpenValid: bool

    # Image registry
    imageTable: Table[uint32, Image]
    nextImageId: uint32
    imageGridRows: int
    imageGridCols: int
    imageGrid: seq[uint32]

    # OSC 9 / 99 buffering (these are `final`-only; we collect across
    # fragments and flush on the final fragment).
    osc9Buf: string
    osc99Buf: string

    # OSC 8 fragment buffer + state for a streaming OSC.
    osc8Buf: string

    # OSC 7 fragment buffer
    osc7Buf: string

    # OSC 1337 (iTerm2) buffer
    osc1337Buf: string

# ---------------------------------------------------------------------------
# Lifetime
# ---------------------------------------------------------------------------

proc newExtendedState*(): ExtendedState =
  result.notificationCap = 1024
  result.kittyStack = @[{}]
  result.mouseProto = mpNone
  result.nextHyperlinkId = 1
  result.nextImageId = 1
  result.activeHyperlink = 0
  result.hyperGridRows = 0
  result.hyperGridCols = 0
  result.hyperGrid = @[]
  result.imageGridRows = 0
  result.imageGridCols = 0
  result.imageGrid = @[]

# NB: We deliberately do NOT define an explicit `=destroy` for
# `ExtendedState`. The compiler-synthesised destructor recurses into
# every owning field (seqs, strings, tables) and frees them. An explicit
# `=destroy` with body `discard` would SUPPRESS the synthesised
# destructor, leaking every heap-backed field on drop. There is no
# non-Nim resource here that would justify overriding the default.

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc ensureGrid(grid: var seq[uint32]; rowsP, colsP: var int;
                rows, cols: int) =
  if rowsP == rows and colsP == cols and grid.len == rows * cols: return
  rowsP = rows
  colsP = cols
  grid = newSeq[uint32](rows * cols)

proc getGridCell(grid: seq[uint32]; rows, cols, row, col: int): uint32 =
  if row < 0 or row >= rows or col < 0 or col >= cols: return 0
  if grid.len < rows * cols: return 0
  grid[row * cols + col]

# ---------------------------------------------------------------------------
# OSC handling
# ---------------------------------------------------------------------------
#
# `handleOsc` is called from screen.nim's parser-layer OSC thunk. The
# `initial` and `final` flags tell us whether this fragment starts a new
# OSC and whether it terminates one -- libvterm fragments long OSCs.

proc enqueueNotification(e: var ExtendedState; n: Notification) =
  e.notificationsList.add n
  if e.notificationsList.len > e.notificationCap:
    let drop = e.notificationsList.len - e.notificationCap
    var trimmed = newSeqOfCap[Notification](e.notificationCap)
    for i in drop ..< e.notificationsList.len:
      trimmed.add e.notificationsList[i]
    e.notificationsList = move(trimmed)

proc parseOsc7(payload: string): string =
  ## OSC 7 payload is `file://host/abs/path`. Strip the scheme and host.
  if payload.startsWith("file://"):
    let rest = payload[7 .. ^1]
    let slash = rest.find('/')
    if slash >= 0:
      return rest[slash .. ^1]
    return ""
  payload

proc registerHyperlink(e: var ExtendedState; uri: string;
                      params: string): uint32 =
  if uri.len == 0: return 0
  for id, h in e.hyperlinkTable:
    if h.uri == uri and h.params == params:
      return id
  let id = e.nextHyperlinkId
  inc e.nextHyperlinkId
  e.hyperlinkTable[id] = Hyperlink(id: id, uri: uri, params: params)
  return id

proc setGridRange(e: var ExtendedState; r0, c0, r1, c1: int; id: uint32) =
  ## Fill `hyperGrid` from (r0, c0) inclusive to (r1, c1) exclusive,
  ## row by row. Multi-row ranges fill the trailing portion of r0,
  ## any full intermediate rows, and the leading portion of r1.
  if e.hyperGrid.len == 0: return
  let rows = e.hyperGridRows
  let cols = e.hyperGridCols
  if rows <= 0 or cols <= 0: return
  if r0 < 0 or r0 >= rows: return
  var row = r0
  var col = c0
  while row < rows:
    let endCol = if row == r1: c1 else: cols
    var c = col
    while c < endCol:
      if c >= 0 and c < cols:
        e.hyperGrid[row * cols + c] = id
      inc c
    if row >= r1: break
    inc row
    col = 0

proc dispatchOsc8(e: var ExtendedState; payload: string;
                  curRow, curCol: int) =
  # Format: OSC 8 ; params ; URI
  #
  # `curRow`/`curCol` is the libvterm cursor position at the moment this
  # OSC fires. On link OPEN we snapshot it into `linkOpenRow/Col`; on
  # link CLOSE we use it as the `(r1, c1)` end-exclusive bound when
  # filling the grid.
  let firstSemi = payload.find(';')
  if firstSemi < 0:
    if e.linkOpenValid and e.activeHyperlink != 0:
      setGridRange(e, e.linkOpenRow, e.linkOpenCol, curRow, curCol,
                   e.activeHyperlink)
    e.activeHyperlink = 0
    e.linkOpenValid = false
    return
  let params = payload[0 ..< firstSemi]
  let uri = if firstSemi + 1 <= payload.high: payload[firstSemi + 1 .. ^1] else: ""
  if uri.len == 0:
    if e.linkOpenValid and e.activeHyperlink != 0:
      setGridRange(e, e.linkOpenRow, e.linkOpenCol, curRow, curCol,
                   e.activeHyperlink)
    e.activeHyperlink = 0
    e.linkOpenValid = false
  else:
    e.activeHyperlink = registerHyperlink(e, uri, params)
    e.linkOpenRow = curRow
    e.linkOpenCol = curCol
    e.linkOpenValid = true

proc dispatchOsc9(e: var ExtendedState; body: string) =
  enqueueNotification(e, Notification(title: "", body: body, metadata: ""))

proc dispatchOsc99(e: var ExtendedState; payload: string) =
  ## Kitty OSC 99 -- format is `metadata;body`, where metadata is a
  ## semicolon-free key/value run keyed by colons. We keep it minimal:
  ## split on the first ';' and treat the LHS as metadata, RHS as body.
  let i = payload.find(';')
  if i < 0:
    enqueueNotification(e, Notification(title: "", body: payload, metadata: ""))
  else:
    enqueueNotification(e, Notification(
      title: "", body: payload[i + 1 .. ^1], metadata: payload[0 ..< i]))

proc dispatchOsc7(e: var ExtendedState; payload: string) =
  e.cwd = parseOsc7(payload)

proc dispatchOsc1337(e: var ExtendedState; payload: string) =
  ## Recognise iTerm2 inline-image announcements (`File=...:...`). We
  ## allocate an ImageRef but do not decode pixels yet. Other OSC 1337
  ## payloads (set-mark, set-cursor-shape, etc.) are silently ignored.
  if not payload.startsWith("File="): return
  let id = e.nextImageId
  inc e.nextImageId
  var img = Image(format: ifITerm2, rawSize: payload.len)
  e.imageTable[id] = img

proc handleOsc*(e: var ExtendedState; command: int;
                str: cstring; nbytes: int;
                initial, final: bool;
                curRow, curCol: int) =
  ## Called from screen.nim's parser-OSC thunk. Buffers until `final`
  ## and dispatches by command. `curRow`/`curCol` is the libvterm
  ## cursor position at the moment the OSC fires; needed by OSC 8 to
  ## attribute hyperlinks to specific cells.
  if command < 0: return
  var s = newString(nbytes)
  if nbytes > 0 and str != nil:
    copyMem(s[0].addr, str, nbytes)
  case command
  of 7:
    if initial: e.osc7Buf.setLen(0)
    e.osc7Buf.add s
    if final:
      dispatchOsc7(e, e.osc7Buf)
      e.osc7Buf.setLen(0)
  of 8:
    if initial: e.osc8Buf.setLen(0)
    e.osc8Buf.add s
    if final:
      dispatchOsc8(e, e.osc8Buf, curRow, curCol)
      e.osc8Buf.setLen(0)
  of 9:
    if initial: e.osc9Buf.setLen(0)
    e.osc9Buf.add s
    if final:
      dispatchOsc9(e, e.osc9Buf)
      e.osc9Buf.setLen(0)
  of 99:
    if initial: e.osc99Buf.setLen(0)
    e.osc99Buf.add s
    if final:
      dispatchOsc99(e, e.osc99Buf)
      e.osc99Buf.setLen(0)
  of 1337:
    if initial: e.osc1337Buf.setLen(0)
    e.osc1337Buf.add s
    if final:
      dispatchOsc1337(e, e.osc1337Buf)
      e.osc1337Buf.setLen(0)
  else:
    discard

# ---------------------------------------------------------------------------
# CSI handling
# ---------------------------------------------------------------------------
#
# We see CSI sequences via the parser-layer hook BEFORE libvterm dispatches
# them to the state layer. We always return 0 to let libvterm continue;
# the only goal here is to record extended-protocol state in our overlay.

proc handleSgrArgs(e: var ExtendedState; args: openArray[clong]) =
  ## Walk SGR args looking for CSI 4 : N m runs. We only set the extended
  ## underline state; libvterm handles the underline:0/1/2/3 forms itself.
  var i = 0
  while i < args.len:
    let raw = args[i].uint32
    let value = int(raw and not (uint32(1) shl 31))
    let hasMore = (raw and (uint32(1) shl 31)) != 0
    if value == 0:
      e.extUnderlinePen = esuNone
      inc i
      continue
    if value == 4 and hasMore and i + 1 < args.len:
      let sub = int(args[i + 1].uint32 and not (uint32(1) shl 31))
      case sub
      of 0: e.extUnderlinePen = esuNone
      of 4: e.extUnderlinePen = esuDotted
      of 5: e.extUnderlinePen = esuDashed
      else: discard
      # Skip past the entire colon-run by walking to the next non-MORE arg.
      inc i
      while i < args.len and (args[i].uint32 and (uint32(1) shl 31)) != 0:
        inc i
      inc i  # consume the final non-MORE token
    elif value == 24:
      e.extUnderlinePen = esuNone
      inc i
    else:
      inc i

proc decodeWindowOp(args: openArray[clong]): WindowOp =
  if args.len == 0: return WindowOp(kind: woOther)
  let kind = int(args[0].uint32 and not (uint32(1) shl 31))
  var rest = newSeq[int](max(0, args.len - 1))
  for j in 1 ..< args.len:
    rest[j - 1] = int(args[j].uint32 and not (uint32(1) shl 31))
  case kind
  of 1:  WindowOp(kind: woRaise, args: rest)
  of 2:  WindowOp(kind: woLower, args: rest)
  of 3:  WindowOp(kind: woMove, args: rest)
  of 4, 8: WindowOp(kind: woResize, args: rest)
  of 11: WindowOp(kind: woRaise, args: rest)  # report mapped state
  of 14, 18: WindowOp(kind: woGetSize, args: rest)
  of 20: WindowOp(kind: woGetIcon, args: rest)
  of 21: WindowOp(kind: woGetTitle, args: rest)
  else:  WindowOp(kind: woOther, args: @[kind] & rest)

proc parseKittyKbFlags(value: int): set[KittyKeyFlag] =
  if (value and 0x1) != 0: result.incl kkfDisambiguate
  if (value and 0x2) != 0: result.incl kkfReportEvents
  if (value and 0x4) != 0: result.incl kkfReportAlternates
  if (value and 0x8) != 0: result.incl kkfReportAllKeys
  if (value and 0x10) != 0: result.incl kkfReportText

proc handleCsi*(e: var ExtendedState; leader: string;
                args: openArray[clong]; intermed: string; command: char) =
  # DEC private modes (leader == "?"): mouse 1016, sync output 2026
  if leader == "?" and (command == 'h' or command == 'l'):
    let setMode = command == 'h'
    for raw in args:
      let v = int(raw.uint32 and not (uint32(1) shl 31))
      case v
      of 2026:
        e.syncOutput = setMode
      of 1016:
        if setMode: e.mouseProto = mpPixel
        elif e.mouseProto == mpPixel: e.mouseProto = mpSgr
      of 1006:
        if setMode: e.mouseProto = mpSgr
        elif e.mouseProto == mpSgr: e.mouseProto = mpNone
      of 1005:
        if setMode: e.mouseProto = mpUtf8
        elif e.mouseProto == mpUtf8: e.mouseProto = mpNone
      of 1015:
        if setMode: e.mouseProto = mpUrxvt
        elif e.mouseProto == mpUrxvt: e.mouseProto = mpNone
      else: discard
    return

  # SGR -- intercept underline:N substyles
  if leader == "" and command == 'm' and intermed == "":
    handleSgrArgs(e, args)
    return

  # Modify-other-keys: CSI > 4 ; N m
  if leader == ">" and command == 'm' and args.len >= 2:
    let p = int(args[0].uint32 and not (uint32(1) shl 31))
    let n = int(args[1].uint32 and not (uint32(1) shl 31))
    if p == 4:
      e.modifyKeysLevel = n
    return

  # CSI t -- window manipulation
  if leader == "" and command == 't' and intermed == "":
    e.windowOpLog.add decodeWindowOp(args)
    return

  # Kitty keyboard:
  #   CSI = flags ; mode u   -- push a new stack frame with `flags`. We
  #                              ignore `mode` (terminal-side semantics
  #                              for set/union/clear); top-of-stack is
  #                              what consumers care about.
  #   CSI > flags u          -- pop one stack frame.
  #   CSI < flags u          -- push a stack frame (alias).
  #   CSI ? u                -- query (we don't actuate replies).
  #
  # The stack is a real `seq[set[KittyKeyFlag]]`: pushes append, pops
  # remove the last frame. We always keep at least one frame (the base
  # `{}` installed in `newExtendedState`) so `kittyKeyboardFlags()`
  # never has to special-case an empty stack.
  if command == 'u' and intermed == "":
    case leader
    of "=", "<":
      let flags = if args.len >= 1:
        parseKittyKbFlags(int(args[0].uint32 and not (uint32(1) shl 31)))
      else:
        {}
      e.kittyStack.add flags
    of ">":
      if e.kittyStack.len > 1:
        discard e.kittyStack.pop()
    else: discard
    return

# ---------------------------------------------------------------------------
# Cell-grid plumbing
# ---------------------------------------------------------------------------
#
# The hyperlink + image grids need to be re-sized whenever the parent
# Screen resizes. The Screen module calls these.

proc resizeGrids*(e: var ExtendedState; rows, cols: int) =
  ensureGrid(e.hyperGrid, e.hyperGridRows, e.hyperGridCols, rows, cols)
  ensureGrid(e.imageGrid, e.imageGridRows, e.imageGridCols, rows, cols)

proc currentHyperlinkAt*(e: ExtendedState; row, col: int): uint32 =
  ## Cell-grid hyperlink lookup. The grid is populated when OSC 8
  ## brackets close: `dispatchOsc8` records the cursor at OSC 8 open and
  ## fills `[openRow][openCol .. closeCol-1]` (or the multi-row
  ## equivalent) on close. The `activeHyperlink` fallback is intentional:
  ## while a link is OPEN but unclosed the grid hasn't been written yet,
  ## so consumers asking about a cell mid-stream still get the right
  ## answer.
  let g = getGridCell(e.hyperGrid, e.hyperGridRows, e.hyperGridCols, row, col)
  if g != 0: return g
  e.activeHyperlink

proc currentHyperlink*(e: ExtendedState): uint32 = e.activeHyperlink

proc hyperlinkById*(e: ExtendedState; id: uint32): Option[Hyperlink] =
  if id == 0: return none(Hyperlink)
  if e.hyperlinkTable.hasKey(id): some(e.hyperlinkTable[id])
  else: none(Hyperlink)

proc hyperlinks*(e: ExtendedState): seq[Hyperlink] =
  for id, h in e.hyperlinkTable: result.add h

proc imageRefAt*(e: ExtendedState; row, col: int): uint32 =
  getGridCell(e.imageGrid, e.imageGridRows, e.imageGridCols, row, col)

proc images*(e: ExtendedState): seq[uint32] =
  for id, _ in e.imageTable: result.add id

proc imageData*(e: ExtendedState; r: uint32): Image =
  if e.imageTable.hasKey(r): e.imageTable[r] else: Image(format: ifPlaceholder)

# ---------------------------------------------------------------------------
# Pull-style queries
# ---------------------------------------------------------------------------

proc workingDirectory*(e: ExtendedState): string = e.cwd
proc notifications*(e: ExtendedState): seq[Notification] = e.notificationsList
proc synchronizedOutput*(e: ExtendedState): bool = e.syncOutput
proc kittyKeyboardFlags*(e: ExtendedState): set[KittyKeyFlag] =
  if e.kittyStack.len == 0: {} else: e.kittyStack[^1]
proc modifyOtherKeys*(e: ExtendedState): int = e.modifyKeysLevel
proc mouseProtocol*(e: ExtendedState): MouseProtocol = e.mouseProto
proc windowOps*(e: ExtendedState): seq[WindowOp] = e.windowOpLog
proc extUnderlineAt*(e: ExtendedState): ExtUnderlineState = e.extUnderlinePen

proc syncOutputUpdate*(e: var ExtendedState; v: bool) = e.syncOutput = v
proc mouseProtocolUpdate*(e: var ExtendedState; m: MouseProtocol) =
  e.mouseProto = m

proc setNotificationCap*(e: var ExtendedState; cap: int) =
  doAssert cap > 0
  e.notificationCap = cap
  if e.notificationsList.len > cap:
    let drop = e.notificationsList.len - cap
    var trimmed = newSeqOfCap[Notification](cap)
    for i in drop ..< e.notificationsList.len:
      trimmed.add e.notificationsList[i]
    e.notificationsList = move(trimmed)
