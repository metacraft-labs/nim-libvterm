## image_types.nim -- value types for the image registry.
##
## These types live in their own module so the pixel decoders
## (`decoders/{kitty,sixel,iterm2}.nim`) can import them without
## introducing a circular dependency on `extended_state.nim`, which is
## the registry-side consumer.
##
## Public-API rules: values only, no `ref`.

type
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
    pixels*: seq[byte]   ## Decoded RGBA. Empty if decode failed or
                         ## was deferred -- callers can fall back to
                         ## `rawSize` for telemetry.
    width*, height*: int  ## Pixels.
    placement*: ImagePlacement
    zIndex*: int
    transparency*: Transparency
    rawSize*: int        ## Bytes of the raw payload, useful for
                         ## telemetry even when pixel decoding fails.
