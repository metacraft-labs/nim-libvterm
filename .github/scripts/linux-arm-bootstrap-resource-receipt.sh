#!/usr/bin/env bash
# Failure-only observation; counters alone do not attribute an earlier kill.
set -euo pipefail
source_root="$GITHUB_WORKSPACE/.reprobuild-src"
receipt_root="$GITHUB_WORKSPACE/.repro-bootstrap-resource"
test ! -e "$receipt_root"
mkdir "$receipt_root"
printf '%s\n' 'Historical compile exit comes from retained setup log; this later process is not that compiler.' > "$receipt_root/scope.txt"
trap 'printf "collection_exit=%s\n" "$?" >> "$receipt_root/collector-status.txt"' EXIT
printf 'current_utc=%s\n' "$(date -u +%FT%TZ)" > "$receipt_root/identity.txt"
printf 'tested_checkout=%s\n' "$(git -C "$GITHUB_WORKSPACE" rev-parse HEAD)" >> "$receipt_root/identity.txt"
if test -d "$source_root/.git"; then
  printf 'bootstrap_source=%s\n' "$(git -C "$source_root" rev-parse HEAD)" >> "$receipt_root/identity.txt"
  git -C "$source_root" status --porcelain > "$receipt_root/bootstrap-source-status.txt"
  for relative in scripts/build_apps.sh Justfile; do
    sha256sum "$source_root/$relative" >> "$receipt_root/bootstrap-input-sha256.txt"
  done
fi
if test -f "$source_root/test-logs/build.log"; then
  sha256sum "$source_root/test-logs/build.log" > "$receipt_root/available-bootstrap-build-log-sha256.txt"
fi
cat /proc/self/cgroup > "$receipt_root/current-process-cgroup.txt"
cat /proc/self/limits > "$receipt_root/current-process-limits.txt"
while IFS=: read -r hierarchy controllers member; do
  if test "$hierarchy" = 0 && test -z "$controllers"; then
    case "$member" in /*) ;; *) exit 1 ;; esac
    case "/$member/" in */../*|*/./*) exit 1 ;; esac
    group="/sys/fs/cgroup$member"
    for filename in memory.events memory.events.local memory.max memory.high memory.current memory.peak pids.max pids.current cpu.max; do
      if test -r "$group/$filename"; then cat "$group/$filename" > "$receipt_root/$filename"; fi
    done
    printf '%s\n' "$group" > "$receipt_root/observed-cgroup-path.txt"
  fi
done < /proc/self/cgroup
for binary in repro reprobuild-nix-daemon; do
  if test -f "$source_root/build/bin/$binary"; then sha256sum "$source_root/build/bin/$binary" >> "$receipt_root/available-bootstrap-binaries-sha256.txt"; fi
done
