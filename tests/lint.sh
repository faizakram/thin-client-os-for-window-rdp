#!/usr/bin/env bash
# =============================================================================
#  ThinClient OS — Shellcheck lint over all shell sources
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

if ! command -v shellcheck >/dev/null 2>&1; then
  echo "shellcheck not installed; skipping lint (install: apt-get install -y shellcheck)"
  exit 0
fi

# Collect shell files: bin scripts, libs, installer, tests, build.sh.
mapfile -t files < <(
  { ls "$ROOT"/scripts/thinclient-* "$ROOT"/scripts/lib/*.sh \
       "$ROOT"/scripts/*.sh "$ROOT"/installer/*.sh "$ROOT"/tests/*.sh \
       "$ROOT"/build.sh "$ROOT"/test-rdp.sh 2>/dev/null; } | sort -u
)

rc=0
for f in "${files[@]}"; do
  [[ -f "$f" ]] || continue
  # SC1091: don't follow sourced files (paths resolve only at runtime).
  # SC2155: allow `local x=$(...)` in these operational scripts.
  if shellcheck -x -e SC1091,SC2155 -S warning "$f"; then
    printf '  ok   %s\n' "${f#"$ROOT"/}"
  else
    printf '  FAIL %s\n' "${f#"$ROOT"/}"; rc=1
  fi
done
exit $rc
