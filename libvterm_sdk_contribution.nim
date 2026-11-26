# Canonical-interface Unix SDK contribution with content-bound provisioning.
# Tool interfaces remain canonical; SDK identity covers expression and owning lock.
import blake3
import repro_project_dsl
const sdkSourceBytes = staticRead("libvterm_nim_zlib_sdk.nix") & "\0" & staticRead("flake.lock")
let sdkIdentity = "blake3:" & blake3.toHex(blake3.digest(sdkSourceBytes))
# Unix contributions bind the owning SDK; native Darwin qualification remains required.
# The SDK contributes the C compiler (which sees zlib) and bash, but no nim: its
# nim is nixpkgs' nim wrapped to name that compiler, and a second nim
# contributor beside the canonical package is ambiguous: Reprobuild gives
# neither one priority and refuses to choose. The contributions reach
# every consumer that `uses: "nim-libvterm"`, and the consumer's own
# `uses: "nim"` brings canonical nim, so leaving canonical nim out of this
# recipe on some platform cannot make that platform's consumers unambiguous.
when defined(linux) or defined(macosx):

  when defined(macosx):
    provisioningFor "clang":
      developInterface
      contributor "libvterm-owning-nim-zlib-sdk"
      nixPackage "libvterm-owning-nim-zlib-sdk", expressionFile = "libvterm_nim_zlib_sdk.nix", executablePath = "bin/clang", lockIdentity = sdkIdentity
  else:
    provisioningFor "gcc":
      developInterface
      contributor "libvterm-owning-nim-zlib-sdk"
      nixPackage "libvterm-owning-nim-zlib-sdk", expressionFile = "libvterm_nim_zlib_sdk.nix", executablePath = "bin/gcc", lockIdentity = sdkIdentity
  provisioningFor "bash":
    developInterface
    contributor "libvterm-owning-nim-zlib-sdk"
    nixPackage "libvterm-owning-nim-zlib-sdk", expressionFile = "libvterm_nim_zlib_sdk.nix", executablePath = "bin/bash", lockIdentity = sdkIdentity
