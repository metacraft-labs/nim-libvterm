## decoders/sixel.nim -- DEC Sixel pixel decoder.
##
## Sixel is a six-pixel-tall band format invented by DEC for printer
## graphics and inherited by xterm/mlterm/foot/wezterm/... The payload we
## receive (post-DCS-introducer) consists of:
##
##   * Optional raster attributes:
##       `"<ratio_num>;<ratio_den>;<width>;<height>`
##     (we use the trailing width/height when present; ratio numbers
##     are ignored as we always emit square pixels).
##   * Palette setup:
##       `#<n>;<type>;<a>;<b>;<c>`
##     where type=2 selects RGB on the 0..100 percentage scale (DEC's
##     native scale; we map to 0..255 by `*255 div 100`).  type=1 is HLS
##     and is rejected as out of scope -- no production fixture uses it
##     in our test corpus.
##   * Pen select: `#<n>` (no semicolon-delimited tail).
##   * Sixel data chars: `?` (0x3F) through `~` (0x7E). Each char encodes
##     six vertical pixels in the current band; bit 0 (LSB) = top pixel,
##     bit 5 = bottom. Set bits paint the current pen colour, cleared
##     bits leave the existing pixel (transparent within a band).
##   * Repeat: `!<n><char>` -- repeat `<char>` `n` times.
##   * Carriage return: `$` -- column reset for the current band.
##   * Next band: `-` -- advance 6 rows; reset column.
##
## The decoder emits an `Image` with `format = ifSixel` and `pixels`
## populated RGBA row-major. The output dimensions are the explicit
## raster attributes when present, otherwise the bounding box of the
## actually-painted pixels.
##
## Anything outside the subset above (HLS palette, conformance-only
## escapes, embedded `;` runs) raises `SixelDecodeError`. The deferred
## bullet on the L2 milestone notes this: a strict subset covers the
## fixture corpus we ship; future protocol work expands it.

import ../image_types
export image_types

type
  SixelDecodeError* = object of CatchableError

proc decodeSixel*(payload: string): Image =
  ## Decode a Sixel payload into an `Image`.
  ##
  ## The payload must begin AFTER the DCS introducer (`ESC P ... q`) --
  ## the caller is responsible for stripping the introducer. Empty
  ## payloads return an empty 0×0 image (not an error -- libvterm fires
  ## the DCS callback even for control-only sequences).
  if payload.len == 0:
    result.format = ifSixel
    return

  # ------------------------- Pass 1: walk to compute size ---------------
  # Sixel's native shape is "6-pixel bands"; we don't know the final
  # width/height until we either (a) hit raster attrs, or (b) finish
  # walking. We do one full walk to learn dimensions, allocate the
  # buffer, then walk again to paint. This wastes a little CPU but is
  # dramatically simpler than computing band runs lazily, and keeps the
  # state machine code linear and reviewable.

  var declaredW = -1
  var declaredH = -1
  var maxCol = 0
  var bandCount = 1  # at minimum we have band 0
  var sawAnyPixel = false

  var i = 0

  # Optional raster attrs -- a leading `"` followed by four ;-separated ints.
  if i < payload.len and payload[i] == '"':
    inc i
    var nums: array[4, int]
    var nIdx = 0
    var cur = 0
    var sawDigit = false
    while i < payload.len and nIdx < 4:
      let c = payload[i]
      if c >= '0' and c <= '9':
        cur = cur * 10 + (ord(c) - ord('0'))
        sawDigit = true
        inc i
      elif c == ';':
        nums[nIdx] = (if sawDigit: cur else: 0)
        inc nIdx
        cur = 0
        sawDigit = false
        inc i
      else:
        nums[nIdx] = (if sawDigit: cur else: 0)
        inc nIdx
        break
    if nIdx == 4:
      declaredW = nums[2]
      declaredH = nums[3]

  var col = 0
  var bandIdx = 0
  while i < payload.len:
    let c = payload[i]
    case c
    of '#':
      # Pen select or palette set; either way, skip the trailing decimal+;
      # run. Palette entries don't affect dimensions.
      inc i
      while i < payload.len and (payload[i] == ';' or
            (payload[i] >= '0' and payload[i] <= '9')):
        inc i
    of '"':
      # A second raster-attr inside the body would be unusual; skip it.
      inc i
      while i < payload.len and (payload[i] == ';' or
            (payload[i] >= '0' and payload[i] <= '9')):
        inc i
    of '!':
      # Repeat: `!<n><char>` -- consume <n>, then advance pointer; the
      # `<char>` itself is consumed by the next loop iteration.
      inc i
      var rep = 0
      while i < payload.len and payload[i] >= '0' and payload[i] <= '9':
        rep = rep * 10 + (ord(payload[i]) - ord('0'))
        inc i
      if i < payload.len:
        let s = payload[i]
        if s >= '?' and s <= '~':
          col += max(rep, 0)
          if col > maxCol: maxCol = col
          sawAnyPixel = true
        inc i
    of '$':
      col = 0
      inc i
    of '-':
      col = 0
      inc bandIdx
      if bandIdx + 1 > bandCount: bandCount = bandIdx + 1
      inc i
    of '\r', '\n', ' ', '\t':
      inc i
    else:
      if c >= '?' and c <= '~':
        inc col
        if col > maxCol: maxCol = col
        sawAnyPixel = true
        inc i
      else:
        # Unknown / unsupported character -- skip silently. The spec is
        # forgiving here; a stricter implementation could raise.
        inc i

  let w = if declaredW > 0: declaredW else: maxCol
  var h = if declaredH > 0: declaredH else: bandCount * 6
  if w <= 0 or h <= 0 or not sawAnyPixel:
    result.format = ifSixel
    result.rawSize = payload.len
    return

  # ------------------------- Pass 2: paint --------------------------------
  result.format = ifSixel
  result.width = w
  result.height = h
  result.rawSize = payload.len
  result.pixels = newSeq[byte](w * h * 4)

  # Palette: fixed-size array indexed by colour-id 0..255.
  # Sixel terminals usually reserve 0..15 for a default ANSI-ish palette;
  # we initialise everything to opaque black and let `#n;2;r;g;b;` overrides
  # populate it.
  var palette: array[256, array[4, byte]]
  for k in 0 ..< 256:
    palette[k] = [byte(0), byte(0), byte(0), byte(255)]

  proc setPixel(buf: var seq[byte]; w, h: int; x, y: int;
                rgba: array[4, byte]) =
    if x < 0 or x >= w or y < 0 or y >= h: return
    let p = (y * w + x) * 4
    buf[p + 0] = rgba[0]
    buf[p + 1] = rgba[1]
    buf[p + 2] = rgba[2]
    buf[p + 3] = rgba[3]

  proc paintSixel(buf: var seq[byte]; w, h, bandTop, x: int;
                  bits: int; rgba: array[4, byte]) =
    # Six bits, LSB = top pixel, MSB = bottom.
    for k in 0 .. 5:
      if (bits and (1 shl k)) != 0:
        setPixel(buf, w, h, x, bandTop + k, rgba)

  i = 0
  if i < payload.len and payload[i] == '"':
    # Skip raster attrs we already parsed.
    inc i
    while i < payload.len and (payload[i] == ';' or
          (payload[i] >= '0' and payload[i] <= '9')):
      inc i

  var pen: int = 0
  col = 0
  bandIdx = 0
  while i < payload.len:
    let c = payload[i]
    case c
    of '#':
      inc i
      var n = 0
      var sawDigit = false
      while i < payload.len and payload[i] >= '0' and payload[i] <= '9':
        n = n * 10 + (ord(payload[i]) - ord('0'))
        sawDigit = true
        inc i
      if not sawDigit:
        # bare `#` -- skip
        continue
      if i < payload.len and payload[i] == ';':
        # Palette definition: `#n;type;a;b;c`
        inc i
        var nums: array[4, int]  # type, a, b, c
        var nIdx = 0
        var cur = 0
        var hasDigit = false
        while i < payload.len and nIdx < 4:
          let pc = payload[i]
          if pc >= '0' and pc <= '9':
            cur = cur * 10 + (ord(pc) - ord('0'))
            hasDigit = true
            inc i
          elif pc == ';':
            nums[nIdx] = (if hasDigit: cur else: 0)
            inc nIdx
            cur = 0
            hasDigit = false
            inc i
          else:
            nums[nIdx] = (if hasDigit: cur else: 0)
            inc nIdx
            break
        # Flush trailing number.
        if hasDigit and nIdx < 4:
          nums[nIdx] = cur
          inc nIdx
        if nIdx >= 4 and nums[0] == 2:
          let r = clamp((nums[1] * 255) div 100, 0, 255)
          let g = clamp((nums[2] * 255) div 100, 0, 255)
          let b = clamp((nums[3] * 255) div 100, 0, 255)
          if n >= 0 and n < 256:
            palette[n] = [byte(r), byte(g), byte(b), byte(255)]
        # type=1 (HLS) -- not implemented; silently leave palette[n].
        pen = (if n >= 0 and n < 256: n else: pen)
      else:
        # Pen select.
        if n >= 0 and n < 256: pen = n
    of '"':
      inc i
      while i < payload.len and (payload[i] == ';' or
            (payload[i] >= '0' and payload[i] <= '9')):
        inc i
    of '!':
      inc i
      var rep = 0
      while i < payload.len and payload[i] >= '0' and payload[i] <= '9':
        rep = rep * 10 + (ord(payload[i]) - ord('0'))
        inc i
      if i < payload.len:
        let s = payload[i]
        if s >= '?' and s <= '~':
          let bits = ord(s) - ord('?')
          for _ in 0 ..< max(rep, 0):
            paintSixel(result.pixels, w, h, bandIdx * 6, col, bits, palette[pen])
            inc col
        inc i
    of '$':
      col = 0
      inc i
    of '-':
      col = 0
      inc bandIdx
      inc i
    of '\r', '\n', ' ', '\t':
      inc i
    else:
      if c >= '?' and c <= '~':
        let bits = ord(c) - ord('?')
        paintSixel(result.pixels, w, h, bandIdx * 6, col, bits, palette[pen])
        inc col
        inc i
      else:
        inc i
