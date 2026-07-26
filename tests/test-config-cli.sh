#!/usr/bin/env bash
# =============================================================================
#  Unit tests — thinclient-config CLI (atomic get/set, mode preservation)
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
export CURRENT_SUITE="config-cli"
source "$HERE/test-helpers.sh"

export TC_LIB_DIR="$ROOT/scripts/lib"
export TC_LOG_DIR="$(mktemp -d)"
export TC_RUN_DIR="$(mktemp -d)"
WORK="$(mktemp -d)"
export TC_CONF="$WORK/server.conf"
cp "$HERE/mock/server.conf" "$TC_CONF"
chmod 640 "$TC_CONF"

CFG="$ROOT/scripts/thinclient-config"

echo "== get =="
assert_eq "10.20.30.40" "$("$CFG" get SERVER_IP)" "CLI get reads a value"

echo "== set (replace existing key) =="
"$CFG" set SERVER_IP 192.168.50.5 >/dev/null
assert_eq "192.168.50.5" "$("$CFG" get SERVER_IP)" "CLI set replaces existing key"
# Ensure only ONE SERVER_IP assignment remains (no duplicate lines).
count="$(grep -c '^SERVER_IP=' "$TC_CONF")"
assert_eq "1" "$count" "no duplicate SERVER_IP line after set"

echo "== set (new key appended) =="
"$CFG" set NEW_KEY hello >/dev/null
assert_eq "hello" "$("$CFG" get NEW_KEY)" "CLI set appends a new key"

echo "== mode preserved after atomic write =="
mode="$(stat -c '%a' "$TC_CONF")"
assert_eq "640" "$mode" "file mode preserved through atomic replace"

echo "== password redaction in list =="
out="$("$CFG" list)"
assert_contains "$out" "PASSWORD=********" "list redacts the stored password"
assert_not_contains "$out" "s3cr3t-pass" "plaintext password never printed by list"

echo "== validation =="
assert_true  "$CFG" validate "valid config passes validation"
echo "SERVER_IP=bad;evil" > "$WORK/bad.conf"
assert_false env TC_CONF="$WORK/bad.conf" "$CFG" validate "invalid config fails validation"

rm -rf "$TC_LOG_DIR" "$TC_RUN_DIR" "$WORK"
finish_suite
