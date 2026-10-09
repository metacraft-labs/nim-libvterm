## Reprobuild project file for nim-libvterm.
##
## **Typed-Cross-Project-Deps rollout, Wave-0 leaf.** This is a pure-Nim
## leaf library — Nim bindings + a value-typed ``Screen`` API + an
## extended-state overlay over a VENDORED copy of libvterm (the neovim
## fork under ``vendor/libvterm/``, compiled in-tree via ``{.compile.}``
## from the FFI layer). It has NO in-scope sibling build dependency of
## its own: the nimble file only ``requires "nim >= 2.0.0"``, every
## importable module lives under this repo's ``src/`` tree, and the one
## external C dependency (libvterm) is vendored, not a workspace repo. So
## the ``uses:`` block is just the toolchain floor and there is no
## ``uses: "<sibling>"`` edge. (``test_helpers.nim`` wraps the system
## ``libz`` via ``zlib_ffi.nim`` to ENCODE PNG fixtures for the
## round-trip tests; the nix dev shell puts zlib's headers/lib on the
## default search paths, so no extra ``--passC:-I`` / ``--passL:-L`` is
## needed on this host — the ``--passC:-w`` below only suppresses the
## vendored C's compiler warnings, matching the repo's ``Justfile``.)
##
## A Mode 1 / Mode 3 hybrid (per
## ``reprobuild-specs/Three-Mode-Convention-System.md``) modelled on the
## canonical ``runquota/repro.nim`` / ``codetracer-trace-format-nim/repro.nim``
## / ``nim-stackable-hooks/repro.nim`` recipes:
##
## * Declares the upstream tool dependencies via ``uses:`` so consumers
##   that depend on this repo (via ``uses: "nim_libvterm"``) pick up the
##   same toolchain floor the nimble file's ``requires "nim >= 2.0.0"``
##   implies.
## * Declares ``library nim_libvterm`` so consumers can express a
##   workspace dependency on this repo. The importable umbrella is
##   ``src/nim_libvterm.nim`` (consumers ``import nim_libvterm``); the
##   submodules under ``src/nim_libvterm/`` (``decoders/png``,
##   ``decoders/sixel``, ``extended_state``, ...) are importable too. The
##   repo ships ``config.nims``; the ``--path:src`` and test path
##   the ``Justfile`` uses are supplied explicitly by the ``paths:``
##   slot on every test BUILD edge below.
## * Emits, per test file under ``tests/``, a BUILD edge
##   (``buildNimUnittest.build``) that compiles ``build/test-bin/<stem>``
##   and an EXECUTE edge (``edge.testBinary.run``) that runs it — the
##   two-edge test template from ``reprobuild-specs/Package-Model.md``
##   §"The test template", exactly as reprobuild's own ``repro.nim`` does
##   it. The BUILD halves collect into ``test-builds`` and the EXECUTE
##   halves into ``test`` so ``repro build test`` / ``repro test``
##   materialise the runnable closure (each execute edge transitively
##   depends on its build edge).
##
## **Compile flags.** Each test BUILD edge reproduces the repo's DEFAULT
## matrix point — ``just test`` → ``test-orc`` → ``nim c … --mm:orc
## -d:release --threads:on`` (see ``Justfile`` ``_matrix orc release on``
## and ``nim-flags``). ``--path:src --path:tests`` is threaded via the
## edge's ``paths:`` slot (also recorded with ``config.nims`` as input);
## ``-d:release`` via ``defines:``; ``--mm:orc`` via ``mm:``;
## ``--threads:on`` via ``threadsOn`` (the wrapper's default). The
## ``--passC:-w`` from ``nim-flags`` (silence the vendored libvterm C
## warnings) rides in via ``extraPassC:``. ``--styleCheck`` /
## ``--skipParentCfg`` / ``--skipUserCfg`` are style/hermeticity switches
## that don't affect the produced binary and aren't part of the typed
## ``nim c`` surface, so they're omitted — the engine compile is already
## hermetic (no parent/user cfg is read from the engine's work root) and
## the corpus compiles + runs identically without them.
##
## **Per-test platform gating.** Every ``tests/*.nim`` test file compiles
## and runs to ``exit 0`` on this Linux host — NONE carries a
## ``{.error.}`` module guard, an OS-only ``import``, or a
## ``when not defined(<os>): quit`` head-guard that would make it
## non-runnable here. The only OS-conditional in the corpus is
## ``test_no_leaks.nim``'s ``when defined(linux): import std/os`` /
## ``when defined(linux): <extra linux-only leak assertions>`` — a
## POSITIVE Linux arm that is simply INCLUDED on this host, not a gate
## that excludes the file. So there are no ``when defined(...)``
## extraction gates: the whole corpus is portable-and-runnable here and
## every edge is unconditionally in the graph. (Mirrors what the repo's
## own ``just test`` runs — the ``Justfile`` ``tests`` list is exactly
## these 39 files; the two remaining ``tests/*.nim`` — ``test_helpers.nim``
## and ``fixtures_jpeg_gif.nim`` — are IMPORTED helper modules with no
## ``suite``/``test`` body, not standalone tests, so they get no edge.)
##
## **Tool provisioning.** ``defaultToolProvisioning "path"`` matches the
## canonical recipes: the nix dev shell supplies ``nim`` and the actual
## platform C backend (macOS ``clang`` or other-platform ``gcc``) on
## ``PATH``, so the weak-local PATH resolver is the right default.
## Without it ``repro build`` refuses to run with "typed tool
## provisioning is required for uses declarations".

import repro_project_dsl
import std/[os, json]
when defined(linux) or defined(macosx):
  import repro_dsl_stdlib/packages/nim as canonicalNim
  when defined(macosx):
    import repro_dsl_stdlib/packages/clang as canonicalBackend
  else:
    import repro_dsl_stdlib/packages/gcc as canonicalBackend
  import repro_dsl_stdlib/packages/bash as canonicalBash
  import libvterm_sdk_contribution

when defined(windows) and defined(arm64):
  import repro_dsl_stdlib/packages/nim as nativeCanonicalNim
  import repro_dsl_stdlib/packages/clang as nativeCanonicalBackend

# ``ct_test_nim_unittest`` supplies the ``buildNimUnittest.build(...)``
# typed-tool used by every test BUILD edge below, and the
# ``edge.testBinary.run(...)`` UFCS dispatch for the EXECUTE edges. It
# re-exports ``repro_project_dsl`` so the import order is unimportant.
#
# Note: like the ``nim-stackable-hooks`` leaf recipe this file does NOT
# import ``ct_test_runner_install`` / call ``installCtTestRunner`` — that
# module is engine-coupled and lives at reprobuild's repo root, importable
# only from reprobuild's own project extraction, not from a sibling
# project. Without it the execute edges route through the engine's default
# direct-binary runner (run the binary, key on exit status), which is
# exactly the exit-0 verification this corpus needs; the Nim ``unittest``
# harness already prints per-suite results and exits non-zero on failure.
import ct_test_nim_unittest

type
  LibvtermTestSpec = object
    ## One entry per test file. ``source`` is the repo-relative ``.nim``
    ## path; ``binary`` is the ``build/test-bin/<stem>`` output.
    source: string
    binary: string

# The corpus — one entry per ``tests/test_*.nim`` standalone test file.
# Mirrors the ``Justfile`` ``tests`` list one-for-one (39 files). Every
# entry compiles + runs to exit 0 on this Linux host (see the module
# docstring's platform-gating note), so there is a single unconditional
# list — no per-OS partition.
const libvtermTestSpecs: seq[LibvtermTestSpec] = @[
  # libvterm-coverage tests (core Screen API against the vendored C).
  LibvtermTestSpec(source: "tests/test_libvterm_basic_hello.nim",
    binary: "build/test-bin/test_libvterm_basic_hello"),
  LibvtermTestSpec(source: "tests/test_libvterm_csi_cursor_move.nim",
    binary: "build/test-bin/test_libvterm_csi_cursor_move"),
  LibvtermTestSpec(source: "tests/test_libvterm_sgr_color_full_palette.nim",
    binary: "build/test-bin/test_libvterm_sgr_color_full_palette"),
  LibvtermTestSpec(source: "tests/test_libvterm_resize_round_trip.nim",
    binary: "build/test-bin/test_libvterm_resize_round_trip"),
  LibvtermTestSpec(source: "tests/test_libvterm_alternate_screen.nim",
    binary: "build/test-bin/test_libvterm_alternate_screen"),
  # Extended-state overlay tests (OSC / CSI / DEC-mode protocols).
  LibvtermTestSpec(source: "tests/test_osc7_cwd.nim",
    binary: "build/test-bin/test_osc7_cwd"),
  LibvtermTestSpec(source: "tests/test_osc8_hyperlink.nim",
    binary: "build/test-bin/test_osc8_hyperlink"),
  LibvtermTestSpec(source: "tests/test_osc9_notification.nim",
    binary: "build/test-bin/test_osc9_notification"),
  LibvtermTestSpec(source: "tests/test_dec_2026_synchronized_output.nim",
    binary: "build/test-bin/test_dec_2026_synchronized_output"),
  LibvtermTestSpec(source: "tests/test_csi_t_window_ops.nim",
    binary: "build/test-bin/test_csi_t_window_ops"),
  LibvtermTestSpec(source: "tests/test_kitty_keyboard.nim",
    binary: "build/test-bin/test_kitty_keyboard"),
  LibvtermTestSpec(source: "tests/test_modify_other_keys.nim",
    binary: "build/test-bin/test_modify_other_keys"),
  LibvtermTestSpec(source: "tests/test_mouse_protocol.nim",
    binary: "build/test-bin/test_mouse_protocol"),
  LibvtermTestSpec(source: "tests/test_state_mirror_pull_after_push.nim",
    binary: "build/test-bin/test_state_mirror_pull_after_push"),
  LibvtermTestSpec(source: "tests/test_image_registry.nim",
    binary: "build/test-bin/test_image_registry"),
  # Image pixel-decoder tests.
  LibvtermTestSpec(source: "tests/test_decode_kitty_rgba.nim",
    binary: "build/test-bin/test_decode_kitty_rgba"),
  LibvtermTestSpec(source: "tests/test_decode_sixel.nim",
    binary: "build/test-bin/test_decode_sixel"),
  LibvtermTestSpec(source: "tests/test_decode_sixel_hls.nim",
    binary: "build/test-bin/test_decode_sixel_hls"),
  LibvtermTestSpec(source: "tests/test_decode_iterm2.nim",
    binary: "build/test-bin/test_decode_iterm2"),
  LibvtermTestSpec(source: "tests/test_decode_png_rgba.nim",
    binary: "build/test-bin/test_decode_png_rgba"),
  LibvtermTestSpec(source: "tests/test_decode_png_rgb.nim",
    binary: "build/test-bin/test_decode_png_rgb"),
  LibvtermTestSpec(source: "tests/test_decode_png_invalid.nim",
    binary: "build/test-bin/test_decode_png_invalid"),
  LibvtermTestSpec(source: "tests/test_decode_jpeg_rgba.nim",
    binary: "build/test-bin/test_decode_jpeg_rgba"),
  LibvtermTestSpec(source: "tests/test_decode_gif_rgba.nim",
    binary: "build/test-bin/test_decode_gif_rgba"),
  # Image-protocol ingest tests (DCS / APC / OSC framing).
  LibvtermTestSpec(source: "tests/test_dcs_sixel_ingest.nim",
    binary: "build/test-bin/test_dcs_sixel_ingest"),
  LibvtermTestSpec(source: "tests/test_apc_kitty_ingest.nim",
    binary: "build/test-bin/test_apc_kitty_ingest"),
  LibvtermTestSpec(source: "tests/test_apc_kitty_png_defer.nim",
    binary: "build/test-bin/test_apc_kitty_png_defer"),
  LibvtermTestSpec(source: "tests/test_kitty_png_ingest.nim",
    binary: "build/test-bin/test_kitty_png_ingest"),
  LibvtermTestSpec(source: "tests/test_iterm2_png_decode.nim",
    binary: "build/test-bin/test_iterm2_png_decode"),
  LibvtermTestSpec(source: "tests/test_iterm2_jpeg_decode.nim",
    binary: "build/test-bin/test_iterm2_jpeg_decode"),
  LibvtermTestSpec(source: "tests/test_iterm2_gif_decode.nim",
    binary: "build/test-bin/test_iterm2_gif_decode"),
  # SGR / underline / API-invariant / leak-budget suites.
  LibvtermTestSpec(source: "tests/test_sgr_extended_underline.nim",
    binary: "build/test-bin/test_sgr_extended_underline"),
  LibvtermTestSpec(source: "tests/test_sgr_underline_color.nim",
    binary: "build/test-bin/test_sgr_underline_color"),
  LibvtermTestSpec(source: "tests/test_api_invariants.nim",
    binary: "build/test-bin/test_api_invariants"),
  # ``test_no_leaks.nim`` — portable; its ``when defined(linux):`` arms
  # ADD Linux-only leak assertions (and ``import std/os``) on this host,
  # they don't gate the file out. Runs to exit 0 everywhere.
  LibvtermTestSpec(source: "tests/test_no_leaks.nim",
    binary: "build/test-bin/test_no_leaks"),
  LibvtermTestSpec(source: "tests/test_gc_traced_inner_block.nim",
    binary: "build/test-bin/test_gc_traced_inner_block"),
  LibvtermTestSpec(source: "tests/test_nimcache_is_worktree_local.nim",
    binary: "build/test-bin/test_nimcache_is_worktree_local"),
  LibvtermTestSpec(source: "tests/test_utf8_split_across_feeds.nim",
    binary: "build/test-bin/test_utf8_split_across_feeds"),
  LibvtermTestSpec(source: "tests/test_wide_glyph_continuation_cell.nim",
    binary: "build/test-bin/test_wide_glyph_continuation_cell"),
]

package nim_libvterm:
  defaultToolProvisioning "path"

  uses:
    # Toolchain floor — the PATH-resolvable binaries the build needs.
    # ``nim`` compiles every test binary (the ``buildNimUnittest.build``
    # edges below); macOS ``clang`` or other-platform ``gcc`` is
    # the actual C back-end ``nim c`` shells out to,
    # which also compiles the vendored libvterm C sources + the
    # ``nim_shim.c`` bit-field helpers the FFI ``{.compile.}``s. The
    # lower bound mirrors the nimble file's ``requires "nim >= 2.0.0"``;
    # ``gcc >=12`` matches the workspace toolchain floor. Sufficient for
    # the path-mode resolver under ``nix develop``.
    "nim >=2.0"
    when defined(linux) or defined(macosx):
      "bash >=4"
    when defined(macosx) or (defined(windows) and defined(arm64)):
      "clang >=14"
    else:
      "gcc >=12"

  # Library declaration — the ``src/`` tree is importable when this
  # package is consumed via ``uses: "nim_libvterm"``. The umbrella is
  # ``src/nim_libvterm.nim``; consumers may also import the submodules
  # under ``src/nim_libvterm/`` directly (e.g. ``nim_libvterm/decoders/png``).
  library nim_libvterm

  build:
    # Two-edge test template (Package-Model.md §"The test template"): one
    # compile BUILD edge + one EXECUTE edge per test file. BUILD halves
    # collect into ``test-builds`` (compile-only verification); EXECUTE
    # halves collect into ``test`` so ``repro test`` / ``repro build
    # test`` materialise the runnable closure (each execute edge
    # transitively depends on its build edge).
    #
    # Compile flags reproduce the repo's default matrix point
    # (``just test`` → ``_matrix orc release on``):
    #   * ``paths = @["src", "tests"]``  — ``--path:src --path:tests``
    #     (``config.nims`` also supplies these paths).
    #   * ``defines = @["release"]``     — ``-d:release``.
    #   * ``mm = "orc"``                 — ``--mm:orc``.
    #   * ``threadsOn`` (default true)   — ``--threads:on``.
    #   * ``extraPassC = @["-w"]``       — silence the vendored libvterm C
    #     warnings (the ``--passC:-w`` baked into ``nim-flags``).
    var nativeArmInputs: seq[string] = @[]
    var nativeArmEnv: seq[(string, string)] = @[]
    when defined(windows) and defined(arm64) and defined(reproProviderMode):
      providerDirectoryInput(".repro/libvterm-native-arm")
      let profilePath = ".repro/libvterm-native-arm/profile.json"
      if not fileExists(profilePath):
        raise newException(ValueError, "Required native Libvterm ARM profile is missing")
      let profile = parseJson(readDevEnvFile(profilePath))
      if profile.kind != JObject or profile["schemaId"].getStr != "nim_libvterm.native-arm-sdk.v1" or
          profile["target"].getStr != "aarch64-w64-mingw32" or
          profile["llvmArchiveSHA256"].getStr != "9a835d5179c9f3a5a783c11a7f14062a249b4765dd11add64a66786864e82ab2" or
          profile["clangSHA256"].getStr != "b9d8bae85fff7df611c1ef2f9ad293f42b4b85e1802cc06d39d411ce1582e0cc" or
          profile["nimVersion"].getStr != "2.2.10" or profile["nativeMachine"].getStr != "AA64":
        raise newException(ValueError, "Native Libvterm ARM profile refused")
      let clang = profile["clang"].getStr
      let nimBin = profile["nimBin"].getStr
      let clangBin = profile["clangBin"].getStr
      let justBin = profile["justBin"].getStr
      for path in [clang, nimBin, clangBin, justBin]:
        if not path.isAbsolute:
          raise newException(ValueError, "Native Libvterm ARM profile path refused")
      if not fileExists(clang) or not fileExists(nimBin / "nim.exe") or not fileExists(justBin / "just.exe"):
        raise newException(ValueError, "Native Libvterm ARM profile member missing")
      nativeArmInputs = @[profilePath]
      nativeArmEnv = @[("PATH", nimBin & ";" & clangBin & ";" & justBin),
                       ("LIBVTERM_NATIVE_ARM_CLANG", clang)]

    var testBuildActions: seq[BuildActionDef] = @[]
    var testExecuteActions: seq[BuildActionDef] = @[]

    proc emitTestPair(source, binary: string;
                      buildActions, executeActions: var seq[BuildActionDef]) =
      var lastSlash = -1
      for i in 0 ..< binary.len:
        if binary[i] == '/' or binary[i] == '\\':
          lastSlash = i
      let stem =
        if lastSlash >= 0: binary[lastSlash + 1 .. ^1]
        else: binary
      let sdkInputs = when defined(linux) or defined(macosx):
        @["libvterm_nim_zlib_sdk.nix", "libvterm_sdk_contribution.nim", "flake.lock"]
      elif defined(windows):
        @["build/windows-zlib-sdk/include/zlib.h",
          "build/windows-zlib-sdk/include/zconf.h",
          "build/windows-zlib-sdk/lib/libz.a",
          "build/windows-zlib-sdk/identity.json",
          "flake.lock"] &
          (when defined(arm64): @["ci/windows-native-arm-sdk.ps1", "ci/native-python-owned-path.ps1"]
           else: @[".github/scripts/windows-native-compiler-sdk.ps1"])
      else: newSeq[string]()
      let zlibPassC = when defined(windows):
        @["-Ibuild/windows-zlib-sdk/include"] &
          (when defined(arm64): @["--target=aarch64-w64-mingw32"] else: @[])
      else: newSeq[string]()
      let zlibPassL = when defined(windows):
        @["-Lbuild/windows-zlib-sdk/lib"] &
          (when defined(arm64): @["--target=aarch64-w64-mingw32"] else: @[])
      else: newSeq[string]()
      let edge = buildNimUnittest.build(
        source = source,
        binary = binary,
        defines = @["release"],
        paths = @["src", "tests"],
        extraInputs = @["src", "tests", "vendor/libvterm", "config.nims",
                        "nim_libvterm.nimble"] & sdkInputs & nativeArmInputs,
        mm = "orc",
        extraPassC = @["-w"] & zlibPassC,
        extraPassL = zlibPassL,
        extraEnv = nativeArmEnv,
        actionId = "nim_libvterm.test_build." & stem)
      when defined(macosx) or (defined(windows) and defined(arm64)):
        appendRegisteredActionToolIdentityRefs(edge.action.id, @["clang"])
      else:
        appendRegisteredActionToolIdentityRefs(edge.action.id, @["gcc"])
      when defined(linux) or defined(macosx):
        appendRegisteredActionToolIdentityRefs(edge.action.id, @["bash"])
      buildActions.add(edge.action)
      # ``registerImplicitName = false`` because the BUILD edge already
      # owns the binary basename as the implicit target name; the explicit
      # ``actionId`` is the execute edge's selector (mirrors reprobuild's
      # ``repro.nim`` two-edge shape).
      let runtimeInputs = if source == "tests/test_nimcache_is_worktree_local.nim":
        @["src", "tests", "vendor/libvterm", "config.nims", "nim_libvterm.nimble"] & sdkInputs
      else: newSeq[string]()
      let executeEdge = edge.testBinary.run(
        actionId = "nim_libvterm.test_execute." & stem,
        registerImplicitName = false,
        extraInputs = runtimeInputs & nativeArmInputs,
        extraEnv = nativeArmEnv)
      if source == "tests/test_nimcache_is_worktree_local.nim":
        appendRegisteredActionToolIdentityRefs(executeEdge.id, @["nim"])
        when defined(linux) or defined(macosx):
          appendRegisteredActionToolIdentityRefs(executeEdge.id, @["bash"])
      executeActions.add(executeEdge)

    for spec in libvtermTestSpecs:
      emitTestPair(spec.source, spec.binary,
        testBuildActions, testExecuteActions)

    discard collect("test", testExecuteActions)
    discard collect("test-builds", testBuildActions)
