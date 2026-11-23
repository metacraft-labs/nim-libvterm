## test_one_nim_contributor_per_platform -- nim-libvterm offers AT MOST ONE nim
## contributor on every platform, so a consumer that resolves `nim` (TermAssert,
## term-assert-cmd) is not left with two eligible contributors.
##
## THE DEFECT (reprobuild-pm issue 2026-11-22-repro-v0-2-31-nim-provisioning-is-
## ambiguous-for-the-termassert-lock). `repro.nim` imported the canonical nim
## package on Linux and macOS, and `libvterm_sdk_contribution.nim` also declared
## `provisioningFor "nim"` on Linux and macOS. A consumer then had two eligible
## nim contributors and the resolver refused ("ambiguous nix provisioning for
## package nim; eligible contributors: canonical-package,
## libvterm-owning-nim-zlib-sdk").
##
## THE FIX. The SDK's nim is registered only on linux-arm64, where the SDK's Nim
## (from nim-fork) and zlib-from-source are the intended realization, and
## canonical nim is not imported there. Everywhere else canonical nim is the one
## nim contributor and the SDK offers none.
##
## WHAT IS ASSERTED. The contributor registrations are macro-time effects, so a
## runtime test cannot count them on one host. The test reads the two sources
## and checks their guards, which are what decide the registrations on each
## platform: the canonical-nim import is guarded by "not linux-arm64", and the
## SDK's `provisioningFor "nim"` sits directly under "linux-arm64". Together the
## two guards give exactly one nim contributor per platform.

import std/[os, strutils, unittest]

const
  RepoRoot = currentSourcePath().parentDir().parentDir()
  CanonicalGuard = "when not (defined(linux) and defined(arm64)):"
  CanonicalImport = "import repro_dsl_stdlib/packages/nim as canonicalNim"
  SdkGuard = "when defined(linux) and defined(arm64):"
  SdkNim = "provisioningFor \"nim\":"

proc readSource(name: string): string =
  readFile(RepoRoot / name)

proc linesOf(text: string): seq[string] =
  text.splitLines()

suite "one nim contributor per platform":

  test "canonical nim is imported only where the SDK's nim is not":
    let lines = linesOf(readSource("repro.nim"))
    var guarded = false
    for i, line in lines:
      if line.strip() == CanonicalImport:
        check i > 0
        check lines[i - 1].strip() == CanonicalGuard
        guarded = true
    check guarded

  test "the SDK declares nim only on linux-arm64":
    let lines = linesOf(readSource("libvterm_sdk_contribution.nim"))
    var declared = 0
    for i, line in lines:
      if line.strip() == SdkNim:
        declared.inc
        check i > 0
        check lines[i - 1].strip() == SdkGuard
        # The guard is a block header, so the declaration is indented under it.
        check line.startsWith("  ")
    check declared == 1
