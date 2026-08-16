## Justfile -- nim-libvterm.
##
## Recipe taxonomy:
##   * Top-level aggregates: `build`, `test`, `lint`, `format` / `fmt`.
##   * `test` runs the *default* matrix point (orc + release + threads:on)
##     for fast iteration. The full charter matrix lives under `test-all`
##     and the per-axis recipes (`test-arc`, `test-asan`, etc.) -- those
##     are what CI invokes per matrix cell.
##   * Hermetic flags (`--skipParentCfg --skipUserCfg`) are baked into
##     `nim-flags` so every invocation gets the same isolation.

set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

alias t := test
alias fmt := format

# Path lookups -- keep the source layout discoverable.
src-paths := "--path:src --path:tests"

# Hermetic + style checks -- applied to every nim invocation in this
# file. The vendored libvterm has its own warnings on some compilers; we
# add `-w` (suppress C warnings) to the C compile via `--passC` so they
# don't drown the test logs. zlib is no longer used by the production
# decoders (stb_image bundles its own inflater) but `tests/test_helpers.nim`
# still wraps the system libz via `zlib_ffi.nim` to *encode* PNG fixtures
# for the round-trip tests. We keep the include/link flags so test
# binaries link cleanly.
nim-flags := "--skipParentCfg --skipUserCfg --styleCheck:usages --styleCheck:error --passC:-w --passC:-I${NIM_LIBVTERM_ZLIB_INCLUDE:-/usr/include} --passL:-L${NIM_LIBVTERM_ZLIB_LIB:-/usr/lib}"

# The ordered list of test files. Adding a new test_*.nim here gates it
# on CI.
tests := "tests/test_libvterm_basic_hello.nim tests/test_libvterm_csi_cursor_move.nim tests/test_libvterm_sgr_color_full_palette.nim tests/test_libvterm_resize_round_trip.nim tests/test_libvterm_alternate_screen.nim tests/test_osc7_cwd.nim tests/test_osc8_hyperlink.nim tests/test_osc9_notification.nim tests/test_dec_2026_synchronized_output.nim tests/test_csi_t_window_ops.nim tests/test_kitty_keyboard.nim tests/test_modify_other_keys.nim tests/test_mouse_protocol.nim tests/test_state_mirror_pull_after_push.nim tests/test_image_registry.nim tests/test_decode_kitty_rgba.nim tests/test_decode_sixel.nim tests/test_decode_sixel_hls.nim tests/test_decode_iterm2.nim tests/test_decode_png_rgba.nim tests/test_decode_png_rgb.nim tests/test_decode_png_invalid.nim tests/test_decode_jpeg_rgba.nim tests/test_decode_gif_rgba.nim tests/test_dcs_sixel_ingest.nim tests/test_apc_kitty_ingest.nim tests/test_apc_kitty_png_defer.nim tests/test_kitty_png_ingest.nim tests/test_iterm2_png_decode.nim tests/test_iterm2_jpeg_decode.nim tests/test_iterm2_gif_decode.nim tests/test_sgr_extended_underline.nim tests/test_sgr_underline_color.nim tests/test_api_invariants.nim tests/test_no_leaks.nim"

# --- Default targets (per repo-requirements.md) ---

# Build: compile every test file as a sanity check (no run).
build:
    @mkdir -p test-logs
    @for t in {{tests}}; do \
      echo "Building $t"; \
      nim c {{nim-flags}} {{src-paths}} --mm:orc -d:release --threads:on \
          -o:test-logs/$(basename $t .nim) $t 2>&1 | tee -a test-logs/build.log; \
    done

# Test: run the default matrix point (orc + release + threads:on).
test: test-orc

# Lint: nim check + nixfmt --check.
lint: lint-nim lint-nix

lint-nim:
    @mkdir -p test-logs
    nim check {{nim-flags}} {{src-paths}} --mm:orc src/nim_libvterm.nim 2>&1 | tee test-logs/lint-nim.log
    @for t in {{tests}}; do \
      echo "Checking $t"; \
      nim check {{nim-flags}} {{src-paths}} --mm:orc $t 2>&1 | tee -a test-logs/lint-nim.log; \
    done

lint-nix:
    nixfmt --check flake.nix

format: format-nim format-nix

format-nim:
    @if command -v nimpretty >/dev/null 2>&1; then \
      nimpretty src/nim_libvterm.nim src/nim_libvterm/*.nim tests/*.nim; \
    else \
      echo "nimpretty not available; skipping Nim formatting"; \
    fi

format-nix:
    nixfmt flake.nix

# Single-source-of-truth version bump.
bump-version version:
    sed -i 's/^version[[:space:]]*=.*/version       = "{{version}}"/' nim_libvterm.nimble

# --- Charter matrix (memory managers x compile modes x threading) ---
#
# Each `test-<axis>` recipe runs the full test list under one
# configuration. CI runs them in parallel via the matrix in
# .github/workflows/ci.yml.

# Memory-manager axes.
test-arc:
    just _matrix arc release on
    just _matrix arc debug on
    just _matrix arc danger on

test-orc:
    just _matrix orc release on
    just _matrix orc debug on
    just _matrix orc danger on

test-refc:
    just _matrix refc release on
    just _matrix refc debug on
    just _matrix refc danger on

# Threading off -- only meaningful on a couple of points; expensive to
# do combinatorially.
test-threads-off:
    just _matrix orc release off
    just _matrix arc release off

# Sanitizers (Linux/amd64 only). Each recipe builds with -d:useMalloc and
# clang+sanitizer flags. We intentionally use `-d:release` AND `-d:danger`
# so we cover both the optimisation level Nim runs benchmarks at AND the
# "live release" build users will see -- sanitizers catch different bugs
# in each.
test-asan:
    @mkdir -p test-logs
    @for mode in release danger; do \
      for t in {{tests}}; do \
        echo "[asan/$mode] $t"; \
        CC=clang CXX=clang++ \
        nim c {{nim-flags}} {{src-paths}} \
          --mm:orc -d:$mode -d:useMalloc \
          --cc:clang \
          --passC:-fsanitize=address --passL:-fsanitize=address \
          --debugger:native \
          -r $t 2>&1 | tee -a test-logs/asan-$mode.log; \
      done; \
    done

test-ubsan:
    @mkdir -p test-logs
    @for t in {{tests}}; do \
      echo "[ubsan] $t"; \
      CC=clang CXX=clang++ \
      nim c {{nim-flags}} {{src-paths}} \
        --mm:orc -d:release -d:useMalloc \
        --cc:clang \
        --passC:-fsanitize=undefined --passL:-fsanitize=undefined \
        -r $t 2>&1 | tee -a test-logs/ubsan.log; \
    done

test-tsan:
    @mkdir -p test-logs
    @for t in {{tests}}; do \
      echo "[tsan] $t"; \
      CC=clang CXX=clang++ \
      nim c {{nim-flags}} {{src-paths}} \
        --mm:orc -d:release -d:useMalloc --threads:on \
        --cc:clang \
        --passC:-fsanitize=thread --passL:-fsanitize=thread \
        -r $t 2>&1 | tee -a test-logs/tsan.log; \
    done

test-lsan:
    @mkdir -p test-logs
    @for t in {{tests}}; do \
      echo "[lsan] $t"; \
      CC=clang CXX=clang++ \
      nim c {{nim-flags}} {{src-paths}} \
        --mm:orc -d:release -d:useMalloc \
        --cc:clang \
        --passC:-fsanitize=leak --passL:-fsanitize=leak \
        -r $t 2>&1 | tee -a test-logs/lsan.log; \
    done

# Valgrind memcheck -- the secondary leak verification beyond LSan.
test-valgrind:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p test-logs
    for t in {{tests}}; do
      out=test-logs/valgrind-$(basename $t .nim)
      echo "[valgrind] $t"
      nim c {{nim-flags}} {{src-paths}} \
        --mm:orc -d:release -d:useMalloc \
        --debugger:native \
        -o:$out $t 2>&1 | tee -a test-logs/valgrind.log
      valgrind --leak-check=full --show-leak-kinds=all --error-exitcode=1 \
        $out 2>&1 | tee -a test-logs/valgrind.log
    done

# Heavy-weight (100k cycle) leak tests -- opt-in.
test-leaks-heavy:
    @mkdir -p test-logs
    nim c {{nim-flags}} {{src-paths}} \
      --mm:orc -d:release -d:nimLibvtermHeavy \
      -r tests/test_no_leaks.nim 2>&1 | tee test-logs/leaks-heavy.log

# Convenience aggregate: everything CI runs on a Linux runner.
test-all: test-arc test-orc test-refc test-threads-off
    @echo "Charter primary matrix complete."

# Internal: one matrix cell.  $1=mm, $2=mode, $3=threads
_matrix mm mode threads:
    @mkdir -p test-logs
    @for t in {{tests}}; do \
      echo "[{{mm}}/{{mode}}/threads:{{threads}}] $t"; \
      nim c {{nim-flags}} {{src-paths}} \
        --mm:{{mm}} -d:{{mode}} --threads:{{threads}} \
        -r $t 2>&1 | tee -a test-logs/{{mm}}-{{mode}}-threads-{{threads}}.log; \
    done

# Clean test-logs and nim caches -- useful before a fresh CI-style run.
clean:
    rm -rf test-logs nim-cache
    find tests -maxdepth 1 -type f -executable -name "test_*" -not -name "*.nim" -delete

# Benchmarks -- placeholder. Real benchmarks (Sixel decode, Kitty
# graphics decode) land alongside the deferred image decoders.
bench:
    @echo "nim-libvterm has no benchmarks yet -- pending image-decoder follow-up."

bench-quick:
    @echo "nim-libvterm has no benchmarks yet -- pending image-decoder follow-up."
