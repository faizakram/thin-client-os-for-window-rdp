#!/usr/bin/env bash
# =============================================================================
#  Unit tests — safe config parser + boolean normalization
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
export CURRENT_SUITE="config-parsing"
source "$HERE/test-helpers.sh"

# Point the library at scratch dirs so logging never touches the real system.
export TC_LOG_DIR="$(mktemp -d)"
export TC_RUN_DIR="$(mktemp -d)"
export TC_CONF="$HERE/mock/server.conf"
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/thinclient-common.sh"

echo "== config parsing =="

assert_eq "10.20.30.40"  "$(conf_get SERVER_IP)"        "reads SERVER_IP"
assert_eq "3389"         "$(conf_get PORT)"             "reads PORT"
assert_eq "developer"    "$(conf_get USERNAME)"         "reads USERNAME"
assert_eq "CORP"         "$(conf_get DOMAIN)"           "reads DOMAIN"
assert_eq "/timeout:20000" "$(conf_get EXTRA_ARGS)"     "reads EXTRA_ARGS with slash value"
assert_eq "fallback"     "$(conf_get NONEXISTENT fallback)" "returns default for missing key"
assert_eq ""             "$(conf_get NONEXISTENT)"      "empty for missing key with no default"

echo "== comment / injection safety =="
inj="$(mktemp)"
cat >"$inj" <<'EOF'
# SERVER_IP=commented.out
SERVER_IP=safe.example.com
EVIL=$(touch /tmp/pwned)
EOF
assert_eq "safe.example.com" "$(TC_CONF="$inj" conf_get SERVER_IP)" "ignores commented duplicate, takes real value"
assert_eq '$(touch /tmp/pwned)' "$(TC_CONF="$inj" conf_get EVIL)"  "does NOT execute command substitution in values"
[[ -e /tmp/pwned ]] && fail "config parser executed injected command" || pass "no code execution from config value"
rm -f "$inj"

echo "== boolean normalization =="
for v in true 1 yes on YES Enabled; do assert_eq "true"  "$(tc_bool "$v")" "tc_bool('$v') -> true"; done
for v in false 0 no off "" garbage;  do assert_eq "false" "$(tc_bool "$v")" "tc_bool('$v') -> false"; done
assert_true  tc_is_true true   "tc_is_true true"
assert_false tc_is_true false  "tc_is_true false"

echo "== validation helpers =="
assert_true  tc_is_valid_host "10.0.0.1"        "valid IPv4 host"
assert_true  tc_is_valid_host "win-server.corp" "valid hostname"
assert_false tc_is_valid_host 'bad;rm -rf'      "rejects host with shell metacharacters"
assert_true  tc_is_valid_port "3389"            "valid port"
assert_false tc_is_valid_port "70000"           "rejects out-of-range port"
assert_false tc_is_valid_port "abc"             "rejects non-numeric port"

rm -rf "$TC_LOG_DIR" "$TC_RUN_DIR"
finish_suite
