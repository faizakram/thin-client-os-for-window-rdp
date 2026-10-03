#!/usr/bin/env bash
# Static check: the ISO must stage EVERY script the OTA ships. The OTA bundle takes
# scripts/thinclient-* by glob; build.sh once kept a hand-written list, and the two new
# security scripts (thinclient-secpolicy, thinclient-ospatch) reached updated devices
# but not fresh installs — which then claimed a version that has them, so no update
# would ever fix it. Caught by inspecting the 1.0.161 ISO before release.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
fail=0
grep -q 'cp "${ROOT}"/scripts/thinclient-\* ' "$ROOT/make-update-bundle.sh" \
  || { echo "  FAIL make-update-bundle.sh no longer ships scripts/thinclient-* by glob"; fail=1; }
grep -qE 'for f in "\$\{PROJECT_ROOT\}"/scripts/thinclient-\*; do' "$ROOT/build.sh" \
  || { echo "  FAIL build.sh does not stage scripts/thinclient-* by glob"; fail=1; }
grep -qE '^\s*local bins=' "$ROOT/build.sh" \
  && { echo "  FAIL build.sh has a hand-kept script list again"; fail=1; }
# Every script the agent/connect/lock load by path must exist in scripts/.
for need in thinclient-secpolicy thinclient-ospatch; do
  [[ -f "$ROOT/scripts/$need" ]] || { echo "  FAIL scripts/$need missing"; fail=1; }
done
[[ $fail -eq 0 ]] && echo "  PASS ISO and OTA ship the same scripts (both by glob)"
exit $fail
