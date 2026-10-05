# Canonical-interface Linux SDK contribution with content-bound provisioning.
# Tool interfaces remain canonical; SDK identity covers expression and owning lock.
import blake3
import repro_project_dsl
const sdkSourceBytes = staticRead("libvterm_nim_zlib_sdk.nix") & "\0" & staticRead("flake.lock")
let sdkIdentity = "blake3:" & blake3.toHex(blake3.digest(sdkSourceBytes))
# Linux qualification only; other platform canonical bindings remain unchanged.
when defined(linux):
  provisioningFor "nim":
    developInterface
    contributor "libvterm-owning-nim-zlib-sdk"
    nixPackage "libvterm-owning-nim-zlib-sdk", expressionFile = "libvterm_nim_zlib_sdk.nix", executablePath = "bin/nim", lockIdentity = sdkIdentity

  provisioningFor "gcc":
    developInterface
    contributor "libvterm-owning-nim-zlib-sdk"
    nixPackage "libvterm-owning-nim-zlib-sdk", expressionFile = "libvterm_nim_zlib_sdk.nix", executablePath = "bin/gcc", lockIdentity = sdkIdentity
  provisioningFor "bash":
    developInterface
    contributor "libvterm-owning-nim-zlib-sdk"
    nixPackage "libvterm-owning-nim-zlib-sdk", expressionFile = "libvterm_nim_zlib_sdk.nix", executablePath = "bin/bash", lockIdentity = sdkIdentity
