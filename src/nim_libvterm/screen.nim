## nim_libvterm/screen.nim -- public Screen API.
##
## Wraps a `VTerm` instance with value semantics, RAII cleanup, and a
## cell-grid query surface. The extended-state overlay (titles, hyperlinks,
## CWD, notifications, etc.) is layered into the same `Screen` value via a
## sibling module (`extended_state`) -- they are deliberately co-located so
## a single `Screen` object captures every observation about the parsed
## terminal stream.
##
## Public-API rules (charter)
## --------------------------
## * Public types are value `object` -- never `ref object`.
## * `=copy` is disabled on `Screen`. Callers move via `=sink` or pass `var`.
## * `=destroy` is the single resource-release path -- it calls `vterm_free`.
## * No raw `ptr` is exposed. The internal `vt: ptr VTerm` field is private
##   to this module (we expose `=destroy` and friends but not the pointer).
## * `cast` is forbidden in the public API. Internally this module uses
##   exactly four `cast[...]` sites at the FFI boundary, each commented
##   inline:
##     1. `innerOf` -- `cast[ptr ScreenInner](pointer)` recovers the
##        Nim self-pointer from libvterm's `user` callback argument.
##     2. `newScreen` -- `cast[ptr ScreenInner](alloc0(...))` narrows a
##        bare `pointer` from the Nim allocator to the typed pointer.
##     3. `feed` -- `cast[cstring](unsafeAddr bytes[0])` adapts an
##        `openArray[byte]` to libvterm's `vterm_input_write` cstring.
##     4. `region` -- `cast[cstring](buf[0].addr)` writes into a Nim
##        `string` buffer via libvterm's `vterm_screen_get_text`.
##
## Memory model
## ------------
## libvterm callbacks fire on the same OS thread as `vterm_input_write`.
## The wrapper allocates one heap block (`ScreenInner`) per `Screen` and
## hands its address to libvterm as the C `user` pointer. Each thunk casts
## the pointer back to `ptr ScreenInner`. The block lives until the
## `Screen` destructor runs, which guarantees lifetime > callback firing.
##
## We could in principle keep `ScreenInner` inline inside the `Screen`
## value, but that would make `=sink` painful (libvterm would hold a
## stale pointer when `Screen` moves). Heap-allocating `ScreenInner`
## once at construction time and pinning it for the screen's life is the
## standard pattern; it is the *only* heap allocation introduced by this
## library on top of libvterm's own allocations.

import std/[options, strutils, unicode]
import ./ffi
import ./extended_state

export extended_state

# ---------------------------------------------------------------------------
# Public value types
# ---------------------------------------------------------------------------

type
  ColorKind* = enum
    ckDefault, ckIndexed, ckRgb

  Color* = object
    ## Color value -- either default / indexed-256 / 24-bit RGB.
    case kind*: ColorKind
    of ckDefault: discard
    of ckIndexed: idx*: uint8
    of ckRgb:
      r*, g*, b*: uint8

  CellAttr* = enum
    ## Boolean SGR attributes that do not have their own typed field.
    caBold, caItalic, caBlink, caReverse, caConceal, caStrike

  UnderlineStyle* = enum
    ## libvterm's 2-bit underline field is `off / single / double / curly`.
    ## Dotted and dashed (CSI 4:4 / 4:5) come from the extended-state
    ## overlay's parser-layer interception and live in `Cell.extUnderline`.
    usNone, usSingle, usDouble, usCurly, usDotted, usDashed

  CursorShape* = enum
    csBlock, csUnderline, csBar

  HyperlinkId* = distinct uint32
  ImageRef* = distinct uint32

  Cell* = object
    ## A single screen cell. `rune` may be `0` for blank cells.
    rune*: Rune
    fg*: Color
    bg*: Color
    attrs*: set[CellAttr]
    underline*: UnderlineStyle
    extUnderline*: UnderlineStyle ## Set by the extended-state overlay when
                                  ## a CSI 4:N m sequence selected dotted/dashed.
    underlineColor*: Color        ## CSI 58 / 59 underline color. `kind ==
                                  ## ckDefault` means "use foreground"
                                  ## (consumers can branch on
                                  ## `cell.underlineColor.kind != ckDefault`).
    width*: int                   ## 0 (continuation), 1, or 2 (wide)
    hyperlinkId*: HyperlinkId     ## 0 if no active hyperlink
    imageRef*: ImageRef           ## 0 if cell is not part of an image

  ScreenInner = object
    ## Heap-pinned per-screen scratch struct that libvterm's C callbacks
    ## see via the user-data pointer.
    ##
    ## We never expose this type publicly. It exists in screen.nim instead
    ## of ffi.nim because it embeds the public `ExtendedState` type.
    vt: ptr VTerm
    rows, cols: int
    extended: ExtendedState

    # libvterm stores the callbacks struct *pointer* it receives -- it
    # does not copy. We pin them inside ScreenInner so the storage lives
    # exactly as long as the libvterm instance does.
    screenCallbacks: VTermScreenCallbacks
    stateFallbacks: VTermStateFallbacks

    # Push-mirror cache for VTermProps libvterm fires via `settermprop`.
    title: string
    iconName: string
    cursorShape: CursorShape
    cursorBlink: bool
    cursorVisible: bool
    altScreenActive: bool
    reverseVideo: bool
    focusReportEnabled: bool
    mouseProtocolNum: int

  Screen* = object
    ## Owning handle for one libvterm instance + extended state.
    ##
    ## Charter rules: not a ref; `=copy` disabled; `=destroy` releases.
    ## All accessor procs take `Screen` (or `var Screen`) by value/ref;
    ## none escape the address of the inner pointer.
    inner: ptr ScreenInner

proc `==`*(a, b: HyperlinkId): bool {.borrow.}
proc `==`*(a, b: ImageRef): bool {.borrow.}
proc `$`*(h: HyperlinkId): string {.borrow.}
proc `$`*(r: ImageRef): string {.borrow.}

const colDefault* = Color(kind: ckDefault)
  ## Sentinel "default color" -- equal to a freshly-zero-initialised
  ## `Color` value. Consumers reading `Cell.underlineColor` can compare
  ## against this to detect "no explicit underline color was set" (in
  ## which case the underline should be drawn in the foreground colour
  ## per the CSI 58/59 specification).

proc `==`*(a, b: Color): bool =
  if a.kind != b.kind: return false
  case a.kind
  of ckDefault: true
  of ckIndexed: a.idx == b.idx
  of ckRgb:     a.r == b.r and a.g == b.g and a.b == b.b

# ---------------------------------------------------------------------------
# Internal: callback thunks
# ---------------------------------------------------------------------------
#
# Each thunk recovers the Nim self-pointer from the C `user` argument via
# the *only* `cast` sites in this module. Both casts are local, the
# argument always non-nil (we always set it via the libvterm setter), and
# the target type matches what we wrote into the user-data slot.

proc innerOf(user: pointer): ptr ScreenInner {.inline.} =
  # CHARTER-JUSTIFIED CAST 1/2: recover the Nim self-pointer that we
  # installed via vterm_state_set_callbacks(state, &cb, addr inner^).
  # libvterm guarantees this round-trip; the input is the same word we
  # passed and the type is fixed by the wrapper.
  cast[ptr ScreenInner](user)

proc settermPropThunk(prop: cint; val: ptr VTermValue;
                      user: pointer): cint {.cdecl.} =
  let inner = innerOf(user)
  if val == nil: return 0
  if prop == VTERM_PROP_CURSORVISIBLE:
    inner.cursorVisible = valBool(val)
  elif prop == VTERM_PROP_CURSORBLINK:
    inner.cursorBlink = valBool(val)
  elif prop == VTERM_PROP_ALTSCREEN:
    inner.altScreenActive = valBool(val)
  elif prop == VTERM_PROP_TITLE:
    let s = valStr(val)
    if s.str != nil:
      let nbytes = fragLen(s)
      var buf = newString(nbytes)
      if nbytes > 0:
        copyMem(buf[0].addr, s.str, nbytes)
      if buf.len > 0:
        inner.title = buf
  elif prop == VTERM_PROP_ICONNAME:
    let s = valStr(val)
    if s.str != nil:
      let nbytes = fragLen(s)
      var buf = newString(nbytes)
      if nbytes > 0:
        copyMem(buf[0].addr, s.str, nbytes)
      if buf.len > 0:
        inner.iconName = buf
  elif prop == VTERM_PROP_REVERSE:
    inner.reverseVideo = valBool(val)
  elif prop == VTERM_PROP_CURSORSHAPE:
    case valNumber(val)
    of VTERM_PROP_CURSORSHAPE_BLOCK: inner.cursorShape = csBlock
    of VTERM_PROP_CURSORSHAPE_UNDERLINE: inner.cursorShape = csUnderline
    of VTERM_PROP_CURSORSHAPE_BAR_LEFT: inner.cursorShape = csBar
    else: discard
  elif prop == VTERM_PROP_MOUSE:
    inner.mouseProtocolNum = valNumber(val)
  elif prop == VTERM_PROP_FOCUSREPORT:
    inner.focusReportEnabled = valBool(val)
  result = 1

proc fallbackOscThunk(command: cint; frag: VTermStringFragment;
                      user: pointer): cint {.cdecl.} =
  ## State-layer OSC fallback. libvterm's `on_osc` consumes OSC 0/1/2/52
  ## itself; everything else (OSC 7, 8, 9, 99, 1337, ...) is handed to
  ## us here.
  ##
  ## Snapshot the libvterm cursor before dispatching: OSC 8 needs the
  ## cursor at link-open and link-close to attribute the URI to the
  ## cells touched by intervening text.
  let inner = innerOf(user)
  var pos: VTermPos
  let state = vterm_obtain_state(inner.vt)
  vterm_state_get_cursorpos(state, addr pos)
  handleOsc(inner.extended, int(command), frag.str, fragLen(frag),
            fragInitial(frag), fragFinal(frag),
            int(pos.row), int(pos.col))
  result = 1

proc fallbackDcsThunk(command: cstring; commandlen: csize_t;
                      frag: VTermStringFragment;
                      user: pointer): cint {.cdecl.} =
  ## State-layer DCS fallback. libvterm itself only consumes
  ## `\x1bP$q...` (status-string queries); every other DCS -- including
  ## Sixel (final byte `q`) -- is routed here.
  let inner = innerOf(user)
  var pos: VTermPos
  let state = vterm_obtain_state(inner.vt)
  vterm_state_get_cursorpos(state, addr pos)
  handleDcs(inner.extended, command, int(commandlen),
            frag.str, fragLen(frag),
            fragInitial(frag), fragFinal(frag),
            int(pos.row), int(pos.col))
  result = 1

proc fallbackApcThunk(frag: VTermStringFragment;
                      user: pointer): cint {.cdecl.} =
  ## State-layer APC fallback. libvterm has no APC handlers itself;
  ## every APC reaches us. We use it for Kitty graphics (leading `G`).
  let inner = innerOf(user)
  var pos: VTermPos
  let state = vterm_obtain_state(inner.vt)
  vterm_state_get_cursorpos(state, addr pos)
  handleApc(inner.extended, frag.str, fragLen(frag),
            fragInitial(frag), fragFinal(frag),
            int(pos.row), int(pos.col))
  result = 1

# NB: A symmetric `fallbackCsiThunk` would let us catch the CSI sequences
# libvterm's state layer can't parse, but we instead pre-scan the byte
# stream in `feed()` so we also cover the DEC private modes that
# libvterm consumes silently without invoking ANY callback. The pre-scan
# is comprehensive; a state-layer CSI fallback would only duplicate the
# information.

# ---------------------------------------------------------------------------
# Lifetime hooks
# ---------------------------------------------------------------------------

proc `=copy`*(dest: var Screen; src: Screen) {.error.}

when defined(gcDestructors):
  proc `=destroy`*(s: Screen) =
    if s.inner != nil:
      if s.inner.vt != nil:
        vterm_free(s.inner.vt)
        s.inner.vt = nil
      `=destroy`(s.inner.extended)
      `=destroy`(s.inner.title)
      `=destroy`(s.inner.iconName)
      dealloc(s.inner)
else:
  # Legacy refc signature -- Nim 2.x's `proc =destroy(s: T)` is gated on
  # `defined(gcDestructors)` (i.e. arc/orc). Under `--mm:refc` the older
  # `proc =destroy(s: var T)` signature is enforced. Same body.
  proc `=destroy`*(s: var Screen) =
    if s.inner != nil:
      if s.inner.vt != nil:
        vterm_free(s.inner.vt)
        s.inner.vt = nil
      `=destroy`(s.inner.extended)
      `=destroy`(s.inner.title)
      `=destroy`(s.inner.iconName)
      dealloc(s.inner)

# ---------------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------------

proc newScreen*(rows, cols: int): Screen =
  ## Create a new Screen with the given dimensions.
  doAssert rows > 0 and cols > 0, "screen dimensions must be positive"
  let inner = cast[ptr ScreenInner](alloc0(sizeof(ScreenInner)))
  # CHARTER-JUSTIFIED CAST 2/2: alloc0 returns `pointer`; we narrow to
  # `ptr ScreenInner`. The size argument matches the target type exactly.
  inner.rows = rows
  inner.cols = cols
  inner.cursorShape = csBlock
  inner.cursorVisible = true
  inner.extended = newExtendedState()
  resizeGrids(inner.extended, rows, cols)
  inner.vt = vterm_new(rows.cint, cols.cint)
  if inner.vt == nil:
    dealloc(inner)
    raise newException(OSError, "vterm_new failed")
  vterm_set_utf8(inner.vt, 1.cint)

  # Materialise the state layer + screen layer. Order matters:
  # * `vterm_obtain_state` registers state's parser callbacks with the
  #   parser layer. We must NOT install our own parser callbacks after
  #   this -- doing so would unhook the state machine entirely.
  # * `vterm_obtain_screen` then registers screen's state callbacks.
  let state = vterm_obtain_state(inner.vt)
  let scr = vterm_obtain_screen(inner.vt)
  # Allocate the alt-screen buffer up-front so DEC mode 1049 / 47 / 1047
  # actually switch to a valid back-buffer rather than no-op-ing in
  # libvterm's "alt-screen disabled" branch.
  vterm_screen_enable_altscreen(scr, 1.cint)
  vterm_screen_reset(scr, 1.cint)

  # Wire the screen-level settermprop callback so we mirror push-mode
  # property updates into pull-style getters. libvterm stores the
  # callbacks struct *pointer* (does not copy), so we park it in the
  # heap-pinned ScreenInner.
  inner.screenCallbacks.settermprop = settermPropThunk
  vterm_screen_set_callbacks(scr, addr inner.screenCallbacks, inner)

  # State-layer fallbacks: we receive every OSC libvterm doesn't itself
  # handle (OSC 7, 8, 9, 99, 1337, ...) plus DCS (Sixel) and APC (Kitty
  # graphics). CSI fallback is intentionally unwired -- the byte-stream
  # pre-scanner in `feed()` covers our extended CSI repertoire (including
  # DEC private modes that libvterm silently consumes without invoking
  # any callback at all).
  inner.stateFallbacks.osc = fallbackOscThunk
  inner.stateFallbacks.dcs = fallbackDcsThunk
  inner.stateFallbacks.apc = fallbackApcThunk
  vterm_state_set_unrecognised_fallbacks(state, addr inner.stateFallbacks, inner)

  result = Screen(inner: inner)

proc size*(s: Screen): tuple[rows, cols: int] =
  if s.inner == nil: return (0, 0)
  (s.inner.rows, s.inner.cols)

proc resize*(s: var Screen; rows, cols: int) =
  doAssert s.inner != nil
  doAssert rows > 0 and cols > 0
  vterm_set_size(s.inner.vt, rows.cint, cols.cint)
  s.inner.rows = rows
  s.inner.cols = cols
  resizeGrids(s.inner.extended, rows, cols)

# ---------------------------------------------------------------------------
# Feeding bytes
# ---------------------------------------------------------------------------

proc parseCsiArgs(bytes: openArray[byte]; start: int): tuple[args: seq[clong], next: int] =
  ## Parse semicolon/colon-separated decimal args. Returns the parsed args
  ## (with the CSI_ARG_FLAG_MORE bit set on every arg followed by a colon)
  ## and the index of the byte after the last digit/separator.
  result.args = @[]
  var i = start
  var cur: clong = 0
  var sawDigit = false
  while i < bytes.len:
    let b = bytes[i]
    if b >= 0x30 and b <= 0x39:
      cur = cur * 10 + clong(int(b) - 0x30)
      sawDigit = true
      inc i
    elif b == 0x3B or b == 0x3A:  # ';' or ':'
      # An empty slot (no digits before the separator) still
      # belongs to the run when the separator is `:` -- e.g. the
      # `::` in `CSI 58:2::R:G:B` is the (empty) colorspace token of
      # the colon-run, not the end of it. We therefore tag empty
      # colon-slots with MORE just like populated ones, so the
      # downstream SGR walker doesn't split the run prematurely.
      let withMore = if b == 0x3A: cur or (clong(1) shl 31) else: cur
      let payload =
        if sawDigit: withMore
        elif b == 0x3A: clong(0) or (clong(1) shl 31)
        else: clong(0)
      result.args.add payload
      cur = 0
      sawDigit = false
      inc i
    else:
      break
  if sawDigit or result.args.len > 0:
    result.args.add cur
  result.next = i

proc parseOneCsi(bytes: openArray[byte]; start: int):
    tuple[ok: bool; leader: char; args: seq[clong]; final: char; next: int] =
  ## Parse a single CSI starting at `bytes[start]` (which must be ESC `[`).
  ## On success, returns the parsed components and the byte index past
  ## the final byte. Returns `ok = false` if the CSI is incomplete (for
  ## example, the terminator falls past `bytes.len`).
  result.ok = false
  if start + 1 >= bytes.len: return
  if bytes[start] != 0x1B or bytes[start + 1] != 0x5B: return
  var j = start + 2
  if j >= bytes.len: return
  # Optional leader byte: ?, >, =, <
  if j < bytes.len and bytes[j] in {0x3F.byte, 0x3E.byte, 0x3D.byte, 0x3C.byte}:
    result.leader = char(bytes[j])
    inc j
  # Parse args
  let parsed = parseCsiArgs(bytes, j)
  result.args = parsed.args
  j = parsed.next
  # Optional intermed bytes (we don't store them but skip)
  while j < bytes.len and bytes[j] >= 0x20 and bytes[j] <= 0x2F:
    inc j
  if j >= bytes.len: return
  result.final = char(bytes[j])
  inc j
  result.next = j
  result.ok = true

proc cursorRowCol(inner: ptr ScreenInner): tuple[row, col: int] =
  ## Read libvterm's current cursor position. Used by the chunked feed
  ## walker to decide which cells were touched by a fixed-pen run.
  var pos: VTermPos
  let state = vterm_obtain_state(inner.vt)
  vterm_state_get_cursorpos(state, addr pos)
  (int(pos.row), int(pos.col))

proc stampExtUnderlineRange(inner: ptr ScreenInner;
                            r0, c0, r1, c1: int) =
  ## Stamp every cell in the half-open rectangle starting at (r0, c0)
  ## inclusive and ending at (r1, c1) exclusive, walking row-major. Used
  ## by the chunked feed walker after libvterm has consumed a fixed-pen
  ## run -- (r0, c0) is the cursor before the run, (r1, c1) the cursor
  ## after. The rectangle wraps at the right margin: cells from c0 to
  ## the row's last column are filled on r0, then any full rows, then
  ## leading cells of r1 up to c1 - 1.
  ##
  ## Both the underline-style (`extUnderlineGrid`) and the underline-
  ## color (`extUnderlineColorGrid`) overlays are stamped here -- they
  ## share the same SGR run boundaries, so a single walk does both.
  let cols = inner.cols
  if cols <= 0: return
  if r0 == r1 and c0 == c1: return  # nothing emitted
  if r0 < 0 or r0 >= inner.rows: return
  var row = r0
  var col = c0
  # Guard against arbitrarily large iterations -- libvterm clamps cursor
  # to the screen, but a defensive cap avoids infinite loops if the
  # snapshot disagreed with our local view.
  var safety = inner.rows * cols + cols
  while safety > 0:
    dec safety
    let endCol = if row == r1: c1 else: cols
    var c = col
    while c < endCol:
      stampExtUnderlineCell(inner.extended, row, c)
      stampExtUnderlineColorCell(inner.extended, row, c)
      inc c
    if row >= r1: break
    inc row
    if row >= inner.rows: break
    col = 0

proc feedRaw(inner: ptr ScreenInner; bytes: openArray[byte]; lo, hi: int) =
  ## Feed `bytes[lo ..< hi]` to libvterm without prescan / chunking.
  if hi <= lo: return
  let p = cast[cstring](unsafeAddr bytes[lo])
  # NB: `cast[cstring]` at the FFI boundary -- same charter justification
  # as the parent `feed`.
  discard vterm_input_write(inner.vt, p, csize_t(hi - lo))

proc feed*(s: var Screen; bytes: openArray[byte]) =
  ## Feed UTF-8 / ANSI bytes from the child process into the parser.
  ##
  ## The byte stream is walked in chunks delimited by SGR sequences. For
  ## each chunk we record libvterm's cursor before and after, then stamp
  ## the per-cell extended-underline grid AND the per-cell underline-
  ## color grid with the active pens. Those grids are the only way to
  ## recover dotted (CSI 4:4) / dashed (CSI 4:5) styles and the colored-
  ## underline state (CSI 58 / 59) because libvterm has no native
  ## representation for either. Single / double / curly remain libvterm-
  ## tracked.
  if s.inner == nil or bytes.len == 0: return
  let inner = s.inner
  let scr = vterm_obtain_screen(inner.vt)
  # Walk the byte stream once, dispatching SGR-pen updates between
  # text-bearing chunks. Other CSIs (DEC modes, mouse, kitty kbd, etc.)
  # are still pre-scanned -- we just dispatch them to the extended-state
  # handler at the same boundary point so the prescan side-effects
  # remain in lockstep with the libvterm-side effects.
  var lo = 0
  var i = 0
  var prevCursor = cursorRowCol(inner)
  while i + 1 < bytes.len:
    if bytes[i] != 0x1B or bytes[i + 1] != 0x5B:  # not ESC [
      inc i
      continue
    let p = parseOneCsi(bytes, i)
    if not p.ok: break
    # We split the stream at every CSI we care about. SGR (`m`) updates
    # the pen; other CSIs go to the extended-state handler unchanged.
    # Everything between `lo` and `i` plus the CSI itself is fed to
    # libvterm together: we want libvterm to consume the SGR before we
    # snapshot the post-cursor for the run that follows.
    let leaderStr = if p.leader == '\0': "" else: $p.leader
    if leaderStr == "" and p.final == 'm':
      # Snapshot cursor BEFORE feeding the upcoming bytes-up-to-CSI run,
      # then feed the run + the SGR itself, then update our pen so the
      # next run's stamping picks up the new pen value.
      feedRaw(inner, bytes, lo, p.next)
      let post = cursorRowCol(inner)
      stampExtUnderlineRange(inner, prevCursor.row, prevCursor.col,
                             post.row, post.col)
      handleCsi(inner.extended, leaderStr, p.args, "", p.final)
      lo = p.next
      prevCursor = post
    else:
      # Non-SGR CSI -- still dispatch to extended-state, but no
      # pen-flush boundary. The bytes flow through with the rest of the
      # current run.
      handleCsi(inner.extended, leaderStr, p.args, "", p.final)
    i = p.next
  # Tail: feed everything after the last SGR (or the whole stream if no
  # SGRs were present) and stamp the resulting cursor advance.
  if lo < bytes.len:
    feedRaw(inner, bytes, lo, bytes.len)
    let post = cursorRowCol(inner)
    stampExtUnderlineRange(inner, prevCursor.row, prevCursor.col,
                           post.row, post.col)
  vterm_screen_flush_damage(scr)

proc feed*(s: var Screen; text: string) {.inline.} =
  ## Convenience overload -- feeds the bytes of a Nim string.
  if text.len == 0: return
  feed(s, toOpenArrayByte(text, 0, text.high))

# ---------------------------------------------------------------------------
# Cell queries
# ---------------------------------------------------------------------------

proc toColor(c: VTermColor): Color =
  if colorIsDefaultFg(c) or colorIsDefaultBg(c):
    Color(kind: ckDefault)
  elif colorIsRgb(c):
    Color(kind: ckRgb, r: colorRed(c), g: colorGreen(c), b: colorBlue(c))
  else:
    Color(kind: ckIndexed, idx: colorIdx(c))

proc cellAt*(s: Screen; row, col: int): Cell =
  ## Return the cell at the given position. Out-of-range queries return a
  ## default-initialised cell (rune `\0`, default colors, no attributes).
  if s.inner == nil: return
  if row < 0 or row >= s.inner.rows or col < 0 or col >= s.inner.cols:
    return
  let scr = vterm_obtain_screen(s.inner.vt)
  var raw: VTermScreenCellRaw
  let pos = VTermPos(row: row.cint, col: col.cint)
  if vterm_screen_get_cell(scr, pos, addr raw) == 0:
    return
  if raw.chars[0] != 0:
    result.rune = Rune(raw.chars[0])
  result.width = int(raw.width)
  result.fg = toColor(raw.fg)
  result.bg = toColor(raw.bg)
  if attrBold(raw.attrs): result.attrs.incl caBold
  if attrItalic(raw.attrs): result.attrs.incl caItalic
  if attrBlink(raw.attrs): result.attrs.incl caBlink
  if attrReverse(raw.attrs): result.attrs.incl caReverse
  if attrConceal(raw.attrs): result.attrs.incl caConceal
  if attrStrike(raw.attrs): result.attrs.incl caStrike
  case attrUnderline(raw.attrs).int
  of 0: result.underline = usNone
  of 1: result.underline = usSingle
  of 2: result.underline = usDouble
  of 3: result.underline = usCurly
  else: result.underline = usNone
  # Extended-state overlay layers
  result.hyperlinkId = HyperlinkId(uint32(currentHyperlinkAt(s.inner.extended, row, col)))
  result.imageRef = ImageRef(uint32(imageRefAt(s.inner.extended, row, col)))
  # Per-cell extended-underline lookup -- libvterm's `attrUnderline` only
  # exposes 0..3 (none/single/double/curly), so dotted (CSI 4:4) and
  # dashed (CSI 4:5) come from the per-cell grid the chunked feed walker
  # maintains. If a cell has both a libvterm-tracked underline AND an
  # ext-underline (which can't happen for the same SGR run -- 4:N maps to
  # exactly one style), `extUnderline` takes precedence so consumers see
  # the modern style.
  result.extUnderline = case extUnderlineCellAt(s.inner.extended, row, col)
    of esuNone: usNone
    of esuDotted: usDotted
    of esuDashed: usDashed
  if result.extUnderline != usNone:
    result.underline = result.extUnderline
  # Per-cell underline-color lookup -- libvterm has no awareness of CSI
  # 58 / 59, so the color is tracked independently in the same chunked
  # walker. `colDefault` (the natural zero-valued `Color`) means "no
  # explicit underline color"; consumers fall back to the foreground.
  let extCol = extUnderlineColorCellAt(s.inner.extended, row, col)
  result.underlineColor = case extCol.kind
    of eckDefault: colDefault
    of eckIndexed: Color(kind: ckIndexed, idx: extCol.idx)
    of eckRgb:     Color(kind: ckRgb, r: extCol.r, g: extCol.g, b: extCol.b)

# ---------------------------------------------------------------------------
# Bulk text queries
# ---------------------------------------------------------------------------

proc region*(s: Screen; row, col, w, h: int): string =
  ## Return a flat UTF-8 string of the requested rectangular region.
  ## libvterm packs cells row-by-row with newline separators between rows.
  if s.inner == nil or w <= 0 or h <= 0: return ""
  let r0 = max(0, row)
  let c0 = max(0, col)
  let r1 = min(s.inner.rows, row + h)
  let c1 = min(s.inner.cols, col + w)
  if r1 <= r0 or c1 <= c0: return ""
  let scr = vterm_obtain_screen(s.inner.vt)
  let rect = VTermRect(startRow: r0.cint, endRow: r1.cint,
                       startCol: c0.cint, endCol: c1.cint)
  # Reasonable upper bound: 4 bytes per cell (max UTF-8 codepoint) plus
  # a newline per row.
  let cap = 4 * (r1 - r0) * (c1 - c0) + (r1 - r0) + 16
  var buf = newString(cap)
  let n = vterm_screen_get_text(scr, cast[cstring](buf[0].addr),
                                csize_t(cap), rect)
  buf.setLen(int(n))
  result = move(buf)

proc contents*(s: Screen): string =
  ## Return the full visible screen text as one UTF-8 string with rows
  ## joined by '\n'.
  if s.inner == nil: return ""
  region(s, 0, 0, s.inner.cols, s.inner.rows)

proc containsText*(s: Screen; needle: string): bool =
  if needle.len == 0: return true
  contents(s).contains(needle)

# ---------------------------------------------------------------------------
# Cursor
# ---------------------------------------------------------------------------

proc cursorPosition*(s: Screen): tuple[row, col: int] =
  if s.inner == nil: return (0, 0)
  let state = vterm_obtain_state(s.inner.vt)
  var pos: VTermPos
  vterm_state_get_cursorpos(state, addr pos)
  (int(pos.row), int(pos.col))

proc cursorShape*(s: Screen): CursorShape =
  if s.inner == nil: csBlock else: s.inner.cursorShape

proc cursorBlink*(s: Screen): bool =
  s.inner != nil and s.inner.cursorBlink

proc cursorVisible*(s: Screen): bool =
  s.inner != nil and s.inner.cursorVisible

# ---------------------------------------------------------------------------
# Mirrored push-state queries
# ---------------------------------------------------------------------------

proc title*(s: Screen): string =
  if s.inner == nil: "" else: s.inner.title

proc iconName*(s: Screen): string =
  if s.inner == nil: "" else: s.inner.iconName

proc altScreenActive*(s: Screen): bool =
  s.inner != nil and s.inner.altScreenActive

proc reverseVideo*(s: Screen): bool =
  s.inner != nil and s.inner.reverseVideo

proc focusReportEnabled*(s: Screen): bool =
  s.inner != nil and s.inner.focusReportEnabled

# ---------------------------------------------------------------------------
# Extended-state queries (forwarded from the overlay)
# ---------------------------------------------------------------------------

proc workingDirectory*(s: Screen): string =
  if s.inner == nil: "" else: workingDirectory(s.inner.extended)

proc notifications*(s: Screen): seq[Notification] =
  if s.inner == nil: @[] else: notifications(s.inner.extended)

proc synchronizedOutput*(s: Screen): bool =
  s.inner != nil and synchronizedOutput(s.inner.extended)

proc kittyKeyboardFlags*(s: Screen): set[KittyKeyFlag] =
  if s.inner == nil: {} else: kittyKeyboardFlags(s.inner.extended)

proc modifyOtherKeys*(s: Screen): int =
  if s.inner == nil: 0 else: modifyOtherKeys(s.inner.extended)

proc mouseProtocol*(s: Screen): MouseProtocol =
  if s.inner == nil: mpNone else: mouseProtocol(s.inner.extended)

proc windowOps*(s: Screen): seq[WindowOp] =
  if s.inner == nil: @[] else: windowOps(s.inner.extended)

proc hyperlinkAt*(s: Screen; row, col: int): Option[Hyperlink] =
  if s.inner == nil: return none(Hyperlink)
  let id = currentHyperlinkAt(s.inner.extended, row, col)
  if id == 0: none(Hyperlink) else: hyperlinkById(s.inner.extended, id)

proc hyperlinks*(s: Screen): seq[Hyperlink] =
  if s.inner == nil: @[] else: hyperlinks(s.inner.extended)

proc images*(s: Screen): seq[ImageRef] =
  if s.inner == nil: return @[]
  let raw = images(s.inner.extended)
  result = newSeq[ImageRef](raw.len)
  for i, r in raw: result[i] = ImageRef(r)

proc imageAt*(s: Screen; row, col: int): Option[ImageRef] =
  if s.inner == nil: return none(ImageRef)
  let r = imageRefAt(s.inner.extended, row, col)
  if r == 0: none(ImageRef) else: some(ImageRef(r))

proc imageData*(s: Screen; r: ImageRef): Image =
  if s.inner == nil: return Image(format: ifPlaceholder)
  imageData(s.inner.extended, uint32(r))
