## nim_libvterm/ffi.nim -- raw FFI bindings to vendored libvterm.
##
## This module is *internal*. Public callers should use `nim_libvterm/screen`
## (re-exported from the top-level `nim_libvterm` module). The raw FFI is
## split out so the Screen wrapper can keep its public-API rules clean
## (no exposed `ptr`, no `cast`).
##
## Build strategy
## --------------
## libvterm is vendored under `vendor/libvterm/`. We compile its .c files
## via `{.compile.}` pragmas, and additionally compile a small Nim-side
## shim (`src/nim_libvterm/c/nim_shim.c`) that exposes libvterm's
## bit-field structs through plain `int`-returning getters, since Nim
## cannot portably express C bit-fields. The shim is the only piece of
## C code in this repo that is NOT part of upstream libvterm.
##
## Header-include policy
## ---------------------
## libvterm's C sources do `#include "vterm_internal.h"` and that header
## in turn does `#include "vterm.h"`. We pass `--passC:-I.../include`
## and `--passC:-I.../src` so the relative `#include` chain resolves.
##
## Charter compliance
## ------------------
## * No `ref object` here -- this whole module is FFI struct mirrors and
##   `importc` declarations.
## * `cast` does not appear in this file. The wrapper's two
##   `cast[ptr ScreenInner](pointer)` callback-thunk sites live in
##   `screen.nim` and are commented inline.
## * Bit-field structs (e.g. `VTermScreenCellAttrs`) are read via the
##   nim_shim accessors -- never decoded from raw bytes here -- so the
##   ABI is whatever the vendored libvterm and the host C compiler agree
##   on.

import std/os

# ---------------------------------------------------------------------------
# Compile + link rules for the vendored C sources + Nim shim
# ---------------------------------------------------------------------------

const
  vendorRoot = currentSourcePath().parentDir().parentDir().parentDir() & "/vendor/libvterm"
  vendorInclude = vendorRoot & "/include"
  vendorSrc = vendorRoot & "/src"
  shimSrc = currentSourcePath().parentDir() & "/c"

# Pass include directories so vendored sources resolve their relative
# `#include "vterm_internal.h"` and `#include "vterm.h"`.
{.passc: "-I" & vendorInclude.}
{.passc: "-I" & vendorSrc.}

# Vendored libvterm sources.
{.compile: vendorSrc & "/encoding.c".}
{.compile: vendorSrc & "/keyboard.c".}
{.compile: vendorSrc & "/mouse.c".}
{.compile: vendorSrc & "/parser.c".}
{.compile: vendorSrc & "/pen.c".}
{.compile: vendorSrc & "/screen.c".}
{.compile: vendorSrc & "/state.c".}
{.compile: vendorSrc & "/unicode.c".}
{.compile: vendorSrc & "/vterm.c".}

# Nim-side shim (bit-field accessors).
{.compile: shimSrc & "/nim_shim.c".}

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

const
  VTERM_MAX_CHARS_PER_CELL* = 6

# ---------------------------------------------------------------------------
# Opaque handles
# ---------------------------------------------------------------------------

type
  VTerm* {.importc, header: "vterm.h", incompleteStruct.} = object
  VTermState* {.importc, header: "vterm.h", incompleteStruct.} = object
  VTermScreen* {.importc, header: "vterm.h", incompleteStruct.} = object

# ---------------------------------------------------------------------------
# Plain value types
# ---------------------------------------------------------------------------

type
  VTermPos* {.importc, header: "vterm.h", bycopy.} = object
    row*: cint
    col*: cint

  VTermRect* {.importc, header: "vterm.h", bycopy.} = object
    startRow* {.importc: "start_row".}: cint
    endRow* {.importc: "end_row".}: cint
    startCol* {.importc: "start_col".}: cint
    endCol* {.importc: "end_col".}: cint

  VTermColor* {.importc, header: "vterm.h", bycopy.} = object
    typ* {.importc: "type".}: uint8
    pad1, pad2, pad3: uint8

  VTermStringFragment* {.importc, header: "vterm.h", bycopy.} = object
    str*: cstring
    # `len` is a packed bit-field (length:30 / initial:1 / final:1). We do
    # NOT expose it directly -- always read via the nim_shim accessors so
    # the bit layout stays compiler-defined.
    lenBits {.importc: "len".}: csize_t

  VTermLineInfo* {.importc, header: "vterm.h", bycopy.} = object
    pad: cuint  # opaque bit-field block

  VTermStateFields* {.importc, header: "vterm.h", bycopy.} = object
    pos*: VTermPos
    lineinfos*: array[2, ptr VTermLineInfo]

  VTermGlyphInfo* {.importc, header: "vterm.h", bycopy.} = object
    chars*: ptr UncheckedArray[uint32]
    width*: cint
    pad: cuint  # opaque bit-field block

  VTermScreenCellAttrs* {.importc, header: "vterm.h", bycopy.} = object
    pad: cuint  # whole bit-field block; readers below

  VTermScreenCellRaw* {.importc: "VTermScreenCell", header: "vterm.h", bycopy.} = object
    chars*: array[VTERM_MAX_CHARS_PER_CELL, uint32]
    width*: cchar
    attrs*: VTermScreenCellAttrs
    fg*: VTermColor
    bg*: VTermColor

  # `union` types -- we leave them as opaque cuint64-shaped blobs and read
  # via dedicated typed accessors. Nim's union support is incomplete with
  # `header:` imports across compiler versions; the accessor pattern is
  # robust.
  VTermValue* {.importc, header: "vterm.h", bycopy.} = object
    # Storage large enough for the largest union member (VTermStringFragment
    # = pointer + size_t + bits ~= 16 bytes on 64-bit). 32 bytes leaves
    # plenty of headroom and matches the C layout's natural alignment.
    raw: array[32, byte]

# ---------------------------------------------------------------------------
# nim_shim accessors
# ---------------------------------------------------------------------------
#
# All bit-field reads + the union-flavoured VTermValue are accessed
# through tiny C helpers compiled into nim_shim.c.

{.push importc.}

proc nim_lvt_attr_bold*(a: ptr VTermScreenCellAttrs): cint
proc nim_lvt_attr_underline*(a: ptr VTermScreenCellAttrs): cint
proc nim_lvt_attr_italic*(a: ptr VTermScreenCellAttrs): cint
proc nim_lvt_attr_blink*(a: ptr VTermScreenCellAttrs): cint
proc nim_lvt_attr_reverse*(a: ptr VTermScreenCellAttrs): cint
proc nim_lvt_attr_conceal*(a: ptr VTermScreenCellAttrs): cint
proc nim_lvt_attr_strike*(a: ptr VTermScreenCellAttrs): cint
proc nim_lvt_attr_dwl*(a: ptr VTermScreenCellAttrs): cint
proc nim_lvt_attr_dhl*(a: ptr VTermScreenCellAttrs): cint

proc nim_lvt_frag_len*(f: ptr VTermStringFragment): cint
proc nim_lvt_frag_initial*(f: ptr VTermStringFragment): cint
proc nim_lvt_frag_final*(f: ptr VTermStringFragment): cint

proc nim_lvt_color_is_rgb*(c: ptr VTermColor): cint
proc nim_lvt_color_is_indexed*(c: ptr VTermColor): cint
proc nim_lvt_color_is_default_fg*(c: ptr VTermColor): cint
proc nim_lvt_color_is_default_bg*(c: ptr VTermColor): cint
proc nim_lvt_color_red*(c: ptr VTermColor): uint8
proc nim_lvt_color_green*(c: ptr VTermColor): uint8
proc nim_lvt_color_blue*(c: ptr VTermColor): uint8
proc nim_lvt_color_idx*(c: ptr VTermColor): uint8

proc nim_lvt_csi_arg_has_more*(a: clong): cint
proc nim_lvt_csi_arg*(a: clong): clong
proc nim_lvt_csi_arg_is_missing*(a: clong): cint

proc nim_lvt_glyph_protected*(g: ptr VTermGlyphInfo): cint
proc nim_lvt_glyph_dwl*(g: ptr VTermGlyphInfo): cint
proc nim_lvt_glyph_dhl*(g: ptr VTermGlyphInfo): cint

{.pop.}

# ---------------------------------------------------------------------------
# Nim-friendly accessor templates (no `cint` noise at call sites)
# ---------------------------------------------------------------------------

template attrBold*(a: VTermScreenCellAttrs): bool =
  nim_lvt_attr_bold(unsafeAddr a) != 0
template attrUnderline*(a: VTermScreenCellAttrs): int =
  int(nim_lvt_attr_underline(unsafeAddr a))
template attrItalic*(a: VTermScreenCellAttrs): bool =
  nim_lvt_attr_italic(unsafeAddr a) != 0
template attrBlink*(a: VTermScreenCellAttrs): bool =
  nim_lvt_attr_blink(unsafeAddr a) != 0
template attrReverse*(a: VTermScreenCellAttrs): bool =
  nim_lvt_attr_reverse(unsafeAddr a) != 0
template attrConceal*(a: VTermScreenCellAttrs): bool =
  nim_lvt_attr_conceal(unsafeAddr a) != 0
template attrStrike*(a: VTermScreenCellAttrs): bool =
  nim_lvt_attr_strike(unsafeAddr a) != 0

template colorIsRgb*(c: VTermColor): bool =
  nim_lvt_color_is_rgb(unsafeAddr c) != 0
template colorIsIndexed*(c: VTermColor): bool =
  nim_lvt_color_is_indexed(unsafeAddr c) != 0
template colorIsDefaultFg*(c: VTermColor): bool =
  nim_lvt_color_is_default_fg(unsafeAddr c) != 0
template colorIsDefaultBg*(c: VTermColor): bool =
  nim_lvt_color_is_default_bg(unsafeAddr c) != 0
template colorRed*(c: VTermColor): uint8 = nim_lvt_color_red(unsafeAddr c)
template colorGreen*(c: VTermColor): uint8 = nim_lvt_color_green(unsafeAddr c)
template colorBlue*(c: VTermColor): uint8 = nim_lvt_color_blue(unsafeAddr c)
template colorIdx*(c: VTermColor): uint8 = nim_lvt_color_idx(unsafeAddr c)

template fragLen*(f: VTermStringFragment): int =
  int(nim_lvt_frag_len(unsafeAddr f))
template fragInitial*(f: VTermStringFragment): bool =
  nim_lvt_frag_initial(unsafeAddr f) != 0
template fragFinal*(f: VTermStringFragment): bool =
  nim_lvt_frag_final(unsafeAddr f) != 0

# ---------------------------------------------------------------------------
# VTermValue accessors (the union)
# ---------------------------------------------------------------------------
#
# We declare a tiny C helper inline that pulls the right field out of the
# union. Done as `header:`-importc rather than via nim_shim so the
# definitions stay close to where they're used.

proc nim_lvt_val_bool(v: ptr VTermValue): cint
  {.importc: "nim_lvt_val_bool".}
proc nim_lvt_val_number(v: ptr VTermValue): cint
  {.importc: "nim_lvt_val_number".}
proc nim_lvt_val_str(v: ptr VTermValue): VTermStringFragment
  {.importc: "nim_lvt_val_str".}
proc nim_lvt_val_color(v: ptr VTermValue): VTermColor
  {.importc: "nim_lvt_val_color".}

template valBool*(v: ptr VTermValue): bool = nim_lvt_val_bool(v) != 0
template valNumber*(v: ptr VTermValue): int = int(nim_lvt_val_number(v))
template valStr*(v: ptr VTermValue): VTermStringFragment = nim_lvt_val_str(v)
template valColor*(v: ptr VTermValue): VTermColor = nim_lvt_val_color(v)

# ---------------------------------------------------------------------------
# Enums (mirrored as `cint` for direct compatibility with the C signature)
# ---------------------------------------------------------------------------

const
  VTERM_ATTR_BOLD* = cint(1)
  VTERM_ATTR_UNDERLINE* = cint(2)
  VTERM_ATTR_ITALIC* = cint(3)
  VTERM_ATTR_BLINK* = cint(4)
  VTERM_ATTR_REVERSE* = cint(5)
  VTERM_ATTR_CONCEAL* = cint(6)
  VTERM_ATTR_STRIKE* = cint(7)
  VTERM_ATTR_FONT* = cint(8)
  VTERM_ATTR_FOREGROUND* = cint(9)
  VTERM_ATTR_BACKGROUND* = cint(10)

  VTERM_PROP_CURSORVISIBLE* = cint(1)
  VTERM_PROP_CURSORBLINK* = cint(2)
  VTERM_PROP_ALTSCREEN* = cint(3)
  VTERM_PROP_TITLE* = cint(4)
  VTERM_PROP_ICONNAME* = cint(5)
  VTERM_PROP_REVERSE* = cint(6)
  VTERM_PROP_CURSORSHAPE* = cint(7)
  VTERM_PROP_MOUSE* = cint(8)
  VTERM_PROP_FOCUSREPORT* = cint(9)

  VTERM_PROP_CURSORSHAPE_BLOCK* = 1
  VTERM_PROP_CURSORSHAPE_UNDERLINE* = 2
  VTERM_PROP_CURSORSHAPE_BAR_LEFT* = 3

# ---------------------------------------------------------------------------
# Callback structs
# ---------------------------------------------------------------------------
#
# All function pointers use the C calling convention. Each callback returns
# `cint` (truthy = "I handled it; do not pass to fallbacks").

## Callback struct layouts.
##
## We define these as plain Nim records (NOT `importc, header:`) because
## libvterm declares the `prop` and `attr` arguments using its own enum
## types (`VTermProp`, `VTermAttr`). Nim's enum-vs-cint compatibility
## fights with `header:` imports here and the resulting C code wouldn't
## compile without warning suppression. The layout is "N function
## pointers in declaration order" -- ABI-compatible by construction.
##
## We pass these by `addr ourStruct` to setter procs that take
## `ptr VTermStateCallbacks` etc. as a `pointer`-equivalent.

type
  VTermParserCallbacks* {.bycopy.} = object
    text*: proc (bytes: cstring; len: csize_t; user: pointer): cint {.cdecl.}
    control*: proc (control: uint8; user: pointer): cint {.cdecl.}
    escape*: proc (bytes: cstring; len: csize_t; user: pointer): cint {.cdecl.}
    csi*: proc (leader: cstring; args: ptr UncheckedArray[clong];
                argcount: cint; intermed: cstring; command: cchar;
                user: pointer): cint {.cdecl.}
    osc*: proc (command: cint; frag: VTermStringFragment;
                user: pointer): cint {.cdecl.}
    dcs*: proc (command: cstring; commandlen: csize_t;
                frag: VTermStringFragment; user: pointer): cint {.cdecl.}
    apc*: proc (frag: VTermStringFragment; user: pointer): cint {.cdecl.}
    pm*: proc (frag: VTermStringFragment; user: pointer): cint {.cdecl.}
    sos*: proc (frag: VTermStringFragment; user: pointer): cint {.cdecl.}
    resize*: proc (rows, cols: cint; user: pointer): cint {.cdecl.}

  VTermStateCallbacks* {.bycopy.} = object
    putglyph*: proc (info: ptr VTermGlyphInfo; pos: VTermPos;
                     user: pointer): cint {.cdecl.}
    movecursor*: proc (pos, oldpos: VTermPos; visible: cint;
                       user: pointer): cint {.cdecl.}
    scrollrect*: proc (rect: VTermRect; downward, rightward: cint;
                       user: pointer): cint {.cdecl.}
    moverect*: proc (dest, src: VTermRect; user: pointer): cint {.cdecl.}
    erase*: proc (rect: VTermRect; selective: cint;
                  user: pointer): cint {.cdecl.}
    initpen*: proc (user: pointer): cint {.cdecl.}
    setpenattr*: proc (attr: cint; val: ptr VTermValue;
                       user: pointer): cint {.cdecl.}
    settermprop*: proc (prop: cint; val: ptr VTermValue;
                        user: pointer): cint {.cdecl.}
    bell*: proc (user: pointer): cint {.cdecl.}
    resize*: proc (rows, cols: cint; fields: ptr VTermStateFields;
                   user: pointer): cint {.cdecl.}
    setlineinfo*: proc (row: cint; newinfo, oldinfo: ptr VTermLineInfo;
                        user: pointer): cint {.cdecl.}
    sbClear*: proc (user: pointer): cint {.cdecl.}

  VTermScreenCallbacks* {.bycopy.} = object
    damage*: proc (rect: VTermRect; user: pointer): cint {.cdecl.}
    moverect*: proc (dest, src: VTermRect; user: pointer): cint {.cdecl.}
    movecursor*: proc (pos, oldpos: VTermPos; visible: cint;
                       user: pointer): cint {.cdecl.}
    settermprop*: proc (prop: cint; val: ptr VTermValue;
                        user: pointer): cint {.cdecl.}
    bell*: proc (user: pointer): cint {.cdecl.}
    resize*: proc (rows, cols: cint; user: pointer): cint {.cdecl.}
    sbPushline*: proc (cols: cint; cells: ptr VTermScreenCellRaw;
                       user: pointer): cint {.cdecl.}
    sbPopline*: proc (cols: cint; cells: ptr VTermScreenCellRaw;
                      user: pointer): cint {.cdecl.}
    sbClear*: proc (user: pointer): cint {.cdecl.}

  VTermStateFallbacks* {.bycopy.} = object
    control*: proc (control: uint8; user: pointer): cint {.cdecl.}
    csi*: proc (leader: cstring; args: ptr UncheckedArray[clong];
                argcount: cint; intermed: cstring; command: cchar;
                user: pointer): cint {.cdecl.}
    osc*: proc (command: cint; frag: VTermStringFragment;
                user: pointer): cint {.cdecl.}
    dcs*: proc (command: cstring; commandlen: csize_t;
                frag: VTermStringFragment; user: pointer): cint {.cdecl.}
    apc*: proc (frag: VTermStringFragment; user: pointer): cint {.cdecl.}
    pm*: proc (frag: VTermStringFragment; user: pointer): cint {.cdecl.}
    sos*: proc (frag: VTermStringFragment; user: pointer): cint {.cdecl.}

# ---------------------------------------------------------------------------
# importc procs
# ---------------------------------------------------------------------------

{.push importc, header: "vterm.h".}

proc vterm_new*(rows, cols: cint): ptr VTerm
proc vterm_free*(vt: ptr VTerm)
proc vterm_get_size*(vt: ptr VTerm; rowsp, colsp: ptr cint)
proc vterm_set_size*(vt: ptr VTerm; rows, cols: cint)
proc vterm_set_utf8*(vt: ptr VTerm; isUtf8: cint)
proc vterm_get_utf8*(vt: ptr VTerm): cint
proc vterm_input_write*(vt: ptr VTerm; bytes: cstring; len: csize_t): csize_t

proc vterm_obtain_state*(vt: ptr VTerm): ptr VTermState
proc vterm_obtain_screen*(vt: ptr VTerm): ptr VTermScreen

proc vterm_state_reset*(state: ptr VTermState; hard: cint)
proc vterm_state_get_cursorpos*(state: ptr VTermState; cursorpos: ptr VTermPos)
proc vterm_state_get_default_colors*(state: ptr VTermState;
                                     defaultFg, defaultBg: ptr VTermColor)
proc vterm_state_set_callbacks*(state: ptr VTermState;
                                callbacks: pointer;
                                user: pointer)
proc vterm_state_set_unrecognised_fallbacks*(state: ptr VTermState;
                                             fallbacks: pointer;
                                             user: pointer)

proc vterm_screen_reset*(screen: ptr VTermScreen; hard: cint)
proc vterm_screen_set_callbacks*(screen: ptr VTermScreen;
                                 callbacks: pointer;
                                 user: pointer)
proc vterm_screen_set_unrecognised_fallbacks*(screen: ptr VTermScreen;
                                              fallbacks: pointer;
                                              user: pointer)
proc vterm_screen_enable_altscreen*(screen: ptr VTermScreen; altscreen: cint)
proc vterm_screen_get_cell*(screen: ptr VTermScreen; pos: VTermPos;
                            cell: ptr VTermScreenCellRaw): cint
proc vterm_screen_get_text*(screen: ptr VTermScreen; str: cstring;
                            len: csize_t; rect: VTermRect): csize_t
proc vterm_screen_flush_damage*(screen: ptr VTermScreen)

proc vterm_parser_set_callbacks*(vt: ptr VTerm;
                                 callbacks: pointer;
                                 user: pointer)

{.pop.}
