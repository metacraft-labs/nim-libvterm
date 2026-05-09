/*
 * stb_image_impl.c -- single-translation-unit implementation expansion of
 * stb_image.h.
 *
 * stb_image.h is a single-header library that ships both declarations
 * and definitions in the same file. Defining STB_IMAGE_IMPLEMENTATION
 * before the include emits the function bodies; doing this in exactly
 * one translation unit keeps the linker happy.
 *
 * We disable the formats this codebase doesn't use (HDR, PIC, PNM) to
 * shrink the binary and the attack surface; PNG / JPEG / GIF / BMP /
 * TGA / PSD remain enabled, which covers every image protocol nim-
 * libvterm cares about (Kitty f=100, iTerm2 OSC 1337 inline images).
 *
 * STBI_NO_STDIO drops the FILE-based entry points (`stbi_load`,
 * `stbi_load_from_file`) -- we only ever decode from in-memory buffers
 * supplied by the terminal protocol.
 */

#define STB_IMAGE_IMPLEMENTATION
#define STBI_NO_STDIO
#define STBI_NO_HDR
#define STBI_NO_PIC
#define STBI_NO_PNM
/* TGA has no magic bytes, so its detector accepts almost any byte
 * stream as a "valid" TGA. That breaks the malformed-input rejection
 * tests (a corrupted PNG header gets misidentified as TGA and decodes
 * to garbage instead of raising). Terminal image protocols never
 * carry TGA so we drop it. PSD likewise -- terminals don't send it. */
#define STBI_NO_TGA
#define STBI_NO_PSD
/* Keep PNG, JPEG, GIF, BMP enabled (covers Kitty f=100 PNG and every
 * common iTerm2 OSC 1337 inner format). */
#include "stb_image.h"
