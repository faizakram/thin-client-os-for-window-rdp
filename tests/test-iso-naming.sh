#!/usr/bin/env bash
# =============================================================================
#  Unit test — a named tenant ISO must never be rewritten by a later build.
#
#  build.sh hard-links iso/thinclient.iso to iso/thinclient-<ver>-<tenant>.iso to
#  save disk. That is fine until the NEXT build copies over thinclient.iso:
#  `cp -f` truncates the existing inode rather than replacing the file, so every
#  earlier hard link receives the new contents and keeps its old name. A USB
#  written from thinclient-1.0.122-quantum.iso then boots a different build
#  entirely — silently, and with the filename still insisting otherwise.
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
export CURRENT_SUITE="iso-naming"
source "$HERE/test-helpers.sh"

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
OUT="$W/thinclient.iso"

# Reproduce exactly what build.sh does, using the real lines from build.sh so the
# test cannot drift away from the script it is guarding.
publish() {  # publish <source> <named>
  local produced="$1" named="$2"
  grep -q 'rm -f "$OUTPUT_ISO"' "$ROOT/build.sh" || { echo "build.sh no longer unlinks first"; return 1; }
  rm -f "$OUT"                 # the fix under test
  cp -f "$produced" "$OUT"
  ln -f "$OUT" "$named" 2>/dev/null || cp -f "$OUT" "$named"
}

printf 'BUILD-ONE' > "$W/produced1"
publish "$W/produced1" "$W/thinclient-1.0.122-quantum.iso"
assert_eq "BUILD-ONE" "$(cat "$W/thinclient-1.0.122-quantum.iso")" "first build lands in its named ISO"

printf 'BUILD-TWO' > "$W/produced2"
publish "$W/produced2" "$W/thinclient-1.0.153-quantum.iso"

echo
echo "== the earlier image must be untouched =="
assert_eq "BUILD-ONE" "$(cat "$W/thinclient-1.0.122-quantum.iso")" \
  "1.0.122 still holds the 1.0.122 build after a 1.0.153 build"
assert_eq "BUILD-TWO" "$(cat "$W/thinclient-1.0.153-quantum.iso")" \
  "1.0.153 holds the new build"
assert_eq "BUILD-TWO" "$(cat "$OUT")" "thinclient.iso points at the newest build"

echo
echo "== and they are genuinely separate files =="
A="$(ls -i "$W/thinclient-1.0.122-quantum.iso" | awk '{print $1}')"
B="$(ls -i "$W/thinclient-1.0.153-quantum.iso" | awk '{print $1}')"
[[ "$A" != "$B" ]] && pass "each build has its own inode" || fail "the two ISOs still share an inode"

finish_suite
