# Local formatting of pinned libvterm sources

The upstream source remains pinned by `PINNED_REVISION` to
`934bc2fbf21800ac3458a499df8820ca5fb45fd3`. This local copy has a formatting
patch that removes one trailing space from each of `src/parser.c`,
`src/unicode.c`, and `include/vterm_keycodes.h`. No C tokens, directives,
string literals, indentation, or line endings change. The pinned upstream
revision identifies the source base; these files do not claim byte identity
with that base after the local formatting patch.

The local formatter also wraps `src/encoding/DECdrawing.inc`,
`src/encoding/uk.inc`, and `src/fullwidth.inc`. Their complete C table tokens,
values, and order remain identical; these fragments contain no comments,
string or character literals, preprocessor directives, or continuations.
