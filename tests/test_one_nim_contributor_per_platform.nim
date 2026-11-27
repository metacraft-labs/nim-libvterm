## test_one_nim_contributor_per_platform -- nim-libvterm contributes no nim of
## its own on any platform, so a consumer that resolves `nim` (TermAssert,
## term-assert-cmd) sees exactly one eligible nim contributor: the canonical
## package.
##
## THE DEFECT. `libvterm_sdk_contribution.nim` declared `provisioningFor "nim"`
## (contributor `libvterm-owning-nim-zlib-sdk`). Every consumer that
## `uses: "nim-libvterm"` receives that contribution, and the consumer's own
## `uses: "nim"` brings the canonical nim package, so the consumer had two
## eligible nim contributors and Reprobuild refused to choose ("ambiguous nix
## provisioning for package nim; eligible contributors: canonical-package,
## libvterm-owning-nim-zlib-sdk"). An earlier attempt kept the SDK's nim on
## linux-arm64 and stopped importing canonical nim there. That made THIS
## recipe unambiguous on that platform but not its consumers, which still
## bring canonical nim themselves: the TermAssert linux-arm64 leg kept failing
## with the same message.
##
## THE FIX. The SDK contributes the compiler and bash only. Canonical nim is
## imported wherever the SDK is, with no platform carve-out.
##
## WHAT IS ASSERTED. The registrations are macro-time effects of the recipe's
## provider, compiled for one platform at a time, so a test running on one
## host cannot count the contributors other platforms would see. The test
## therefore checks the two sources at compile time (`staticRead`, so both
## files are declared inputs of this test's build edge): the SDK declares no
## nim on any branch, and the canonical-nim import sits in the same block as
## the SDK import with no further guard. Either regression -- an SDK nim on any
## platform, or a guard that drops canonical nim somewhere -- fails a check.
##
## Plain `doAssert` checks, like the rest of this suite, rather than
## std/unittest: unittest's global console formatter is allocated at module
## init and never freed, which valgrind (`just test-valgrind`) reports as a
## possibly-lost block and fails the module on.

import std/strutils

const
  ReproNim = staticRead("../repro.nim")
  SdkContribution = staticRead("../libvterm_sdk_contribution.nim")
  UnixGuard = "when defined(linux) or defined(macosx):"
  CanonicalImport = "import repro_dsl_stdlib/packages/nim as canonicalNim"
  SdkImport = "import libvterm_sdk_contribution"

proc indentOf(line: string): int =
  ## Leading spaces of `line`; the recipe uses spaces only.
  while result < line.len and line[result] == ' ':
    inc result

proc codeLines(text: string): seq[string] =
  ## The lines of `text` with comments and blank lines removed, so prose that
  ## mentions a construct is never mistaken for the construct.
  for line in text.splitLines():
    let stripped = line.strip()
    if stripped.len > 0 and not stripped.startsWith("#"):
      result.add line

proc enclosingHeader(lines: seq[string]; index: int): string =
  ## The nearest preceding line indented less than `lines[index]`: the block
  ## header that guards it ("" at top level).
  let own = indentOf(lines[index])
  var i = index - 1
  while i >= 0:
    if indentOf(lines[i]) < own:
      return lines[i].strip()
    dec i
  ""

proc sdkDeclaresNoNim() =
  ## The SDK contribution declares no nim on any platform.
  for line in codeLines(SdkContribution):
    let stripped = line.strip()
    doAssert not stripped.startsWith("provisioningFor \"nim\""),
      "libvterm_sdk_contribution.nim declares a nim: " & stripped
    doAssert not stripped.contains("executablePath = \"bin/nim\""),
      "libvterm_sdk_contribution.nim declares a nim executable: " & stripped
  echo "  [OK] the SDK contribution declares no nim on any platform"

proc canonicalNimBesideSdk() =
  ## Canonical nim is imported wherever the SDK contribution is.
  let lines = codeLines(ReproNim)
  var canonicalHeaders, sdkHeaders: seq[string]
  for i, line in lines:
    case line.strip()
    of CanonicalImport: canonicalHeaders.add enclosingHeader(lines, i)
    of SdkImport: sdkHeaders.add enclosingHeader(lines, i)
    else: discard
  doAssert canonicalHeaders == @[UnixGuard],
    "canonical nim import guards in repro.nim: " & $canonicalHeaders &
    ", expected " & $(@[UnixGuard])
  doAssert sdkHeaders == @[UnixGuard],
    "SDK contribution import guards in repro.nim: " & $sdkHeaders &
    ", expected " & $(@[UnixGuard])
  echo "  [OK] canonical nim is imported wherever the SDK contribution is"

echo "[Suite] one nim contributor per platform"
sdkDeclaresNoNim()
canonicalNimBesideSdk()
echo "test_one_nim_contributor_per_platform OK"
