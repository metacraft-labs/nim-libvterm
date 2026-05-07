/*
 * nim_shim.c -- helpers for nim-libvterm to read libvterm's bit-field
 * attribute struct without depending on a particular C compiler's
 * bit-field layout. Nim cannot portably express
 *   unsigned int bold : 1;
 * so we expose getters that the Nim FFI declares as plain functions.
 *
 * This file is NOT part of upstream libvterm. It lives in the nim-libvterm
 * source tree (`src/nim_libvterm/c/`) and is compiled alongside the
 * vendored libvterm via {.compile.} pragmas in src/nim_libvterm/ffi.nim.
 */

#include "vterm.h"
#include <string.h>

/* Cell-attribute bit-field readers ---------------------------------- */

int nim_lvt_attr_bold(const VTermScreenCellAttrs *a) { return a->bold; }
int nim_lvt_attr_underline(const VTermScreenCellAttrs *a) { return a->underline; }
int nim_lvt_attr_italic(const VTermScreenCellAttrs *a) { return a->italic; }
int nim_lvt_attr_blink(const VTermScreenCellAttrs *a) { return a->blink; }
int nim_lvt_attr_reverse(const VTermScreenCellAttrs *a) { return a->reverse; }
int nim_lvt_attr_conceal(const VTermScreenCellAttrs *a) { return a->conceal; }
int nim_lvt_attr_strike(const VTermScreenCellAttrs *a) { return a->strike; }
int nim_lvt_attr_dwl(const VTermScreenCellAttrs *a) { return a->dwl; }
int nim_lvt_attr_dhl(const VTermScreenCellAttrs *a) { return a->dhl; }

/* String-fragment bit-field readers --------------------------------- */
int nim_lvt_frag_len(const VTermStringFragment *f) { return (int)f->len; }
int nim_lvt_frag_initial(const VTermStringFragment *f) { return f->initial; }
int nim_lvt_frag_final(const VTermStringFragment *f) { return f->final; }

/* Color helpers ----------------------------------------------------- */
int nim_lvt_color_is_rgb(const VTermColor *c) { return VTERM_COLOR_IS_RGB(c); }
int nim_lvt_color_is_indexed(const VTermColor *c) { return VTERM_COLOR_IS_INDEXED(c); }
int nim_lvt_color_is_default_fg(const VTermColor *c) { return VTERM_COLOR_IS_DEFAULT_FG(c); }
int nim_lvt_color_is_default_bg(const VTermColor *c) { return VTERM_COLOR_IS_DEFAULT_BG(c); }
unsigned char nim_lvt_color_red(const VTermColor *c) { return c->rgb.red; }
unsigned char nim_lvt_color_green(const VTermColor *c) { return c->rgb.green; }
unsigned char nim_lvt_color_blue(const VTermColor *c) { return c->rgb.blue; }
unsigned char nim_lvt_color_idx(const VTermColor *c) { return c->indexed.idx; }

/* CSI argument helpers ---------------------------------------------- */
int nim_lvt_csi_arg_has_more(long a) { return CSI_ARG_HAS_MORE(a); }
long nim_lvt_csi_arg(long a) { return CSI_ARG(a); }
int nim_lvt_csi_arg_is_missing(long a) { return CSI_ARG_IS_MISSING(a); }

/* Glyph-info bit-field readers -------------------------------------- */
int nim_lvt_glyph_protected(const VTermGlyphInfo *g) { return g->protected_cell; }
int nim_lvt_glyph_dwl(const VTermGlyphInfo *g) { return g->dwl; }
int nim_lvt_glyph_dhl(const VTermGlyphInfo *g) { return g->dhl; }

/* VTermValue union accessors ---------------------------------------- */

int nim_lvt_val_bool(const VTermValue *v) { return v->boolean; }
int nim_lvt_val_number(const VTermValue *v) { return v->number; }

VTermStringFragment nim_lvt_val_str(const VTermValue *v) { return v->string; }

VTermColor nim_lvt_val_color(const VTermValue *v) { return v->color; }
