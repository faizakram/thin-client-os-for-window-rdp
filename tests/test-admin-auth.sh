#!/usr/bin/env bash
# =============================================================================
#  Unit tests — admin password verification + lockout
#  Security-critical: verifies the salted-hash check accepts the right password,
#  rejects wrong ones, and never stores/prints plaintext.
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
export CURRENT_SUITE="admin-auth"
source "$HERE/test-helpers.sh"

export TC_LIB_DIR="$ROOT/scripts/lib"
export TC_LOG_DIR="$(mktemp -d)"
export TC_CONF="$HERE/mock/server.conf"

# A fresh admin.conf with a known password: "changeme".
WORK="$(mktemp -d)"
export TC_ADMIN_CONF="$WORK/admin.conf"
cp "$ROOT/config/admin.conf" "$TC_ADMIN_CONF"

ADMINCTL="$ROOT/scripts/thinclient-adminctl"

check_pw() {
  # Fresh run dir each call so the lockout counter never bleeds across cases.
  local rundir; rundir="$(mktemp -d)"
  printf '%s' "$1" | env TC_RUN_DIR="$rundir" bash "$ADMINCTL" check 2>/dev/null
  local rc=$?
  rm -rf "$rundir"
  return $rc
}

echo "== password verification =="
out="$(check_pw changeme)";  rc=$?
assert_eq "OK"   "$out" "correct password returns OK"
assert_eq "0"    "$rc"  "correct password exits 0"

out="$(check_pw wrongpass)"; rc=$?
assert_eq "FAIL" "$out" "wrong password returns FAIL"
assert_eq "1"    "$rc"  "wrong password exits 1"

out="$(check_pw '')"; rc=$?
assert_eq "FAIL" "$out" "empty password returns FAIL"

echo "== lockout after repeated failures =="
LRUN="$(mktemp -d)"
# admin.conf default: ADMIN_MAX_ATTEMPTS=5
for i in 1 2 3 4 5; do
  printf 'nope%s' "$i" | env TC_RUN_DIR="$LRUN" bash "$ADMINCTL" check >/dev/null 2>&1 || true
done
out="$(printf 'changeme' | env TC_RUN_DIR="$LRUN" bash "$ADMINCTL" check 2>/dev/null || true)"
assert_eq "LOCKED" "$out" "locks out after 5 failed attempts (even with correct pw)"
rm -rf "$LRUN"

echo "== no plaintext leakage =="
# Only active (non-comment) config lines matter; a doc comment may name the default.
noncomment="$(grep -vE '^[[:space:]]*#' "$TC_ADMIN_CONF")"
assert_not_contains "$noncomment" "changeme" "no plaintext password in active config lines"
assert_contains "$noncomment" 'ADMIN_PASSWORD_HASH=$6$' "password is stored as a SHA-512 crypt hash"

rm -rf "$TC_LOG_DIR" "$WORK"
finish_suite
