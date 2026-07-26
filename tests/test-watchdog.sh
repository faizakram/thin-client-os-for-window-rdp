#!/usr/bin/env bash
# =============================================================================
#  Unit tests — runtime state + heartbeat semantics the watchdog relies on
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
export CURRENT_SUITE="watchdog-state"
source "$HERE/test-helpers.sh"

export TC_LOG_DIR="$(mktemp -d)"
export TC_RUN_DIR="$(mktemp -d)"
export TC_CONF="$HERE/mock/server.conf"
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/thinclient-common.sh"

echo "== state round-trip =="
tc_set_state "CONNECTED"
assert_eq "CONNECTED" "$(tc_get_state)" "state persists and reads back"
tc_set_state "CONNECTING"
assert_eq "CONNECTING" "$(tc_get_state)" "state can be updated"
assert_eq "UNKNOWN" "$(TC_STATE_FILE=/nonexistent/x tc_get_state)" "missing state file -> UNKNOWN"

echo "== heartbeat freshness =="
tc_heartbeat
now="$(date +%s)"
hb="$(cat "$TC_HEARTBEAT_FILE")"
age=$(( now - hb ))
[[ "$hb" =~ ^[0-9]+$ ]] && pass "heartbeat writes an epoch timestamp" || fail "heartbeat not numeric" "$hb"
(( age >= 0 && age <= 2 )) && pass "fresh heartbeat age within tolerance ($age s)" || fail "heartbeat age unexpected" "$age"

echo "== staleness decision (mirrors watchdog threshold math) =="
interval=5
stale_threshold=$(( interval * 3 )); (( stale_threshold < 15 )) && stale_threshold=15
# Simulate a stale heartbeat by backdating it 60s.
printf '%s' "$(( now - 60 ))" >"$TC_HEARTBEAT_FILE"
old="$(cat "$TC_HEARTBEAT_FILE")"; age=$(( now - old ))
if (( age > stale_threshold )); then pass "60s-old heartbeat is judged stale (age=$age > $stale_threshold)"
else fail "stale detection failed" "age=$age threshold=$stale_threshold"; fi
# A fresh heartbeat must NOT be judged stale.
tc_heartbeat; fresh="$(cat "$TC_HEARTBEAT_FILE")"; age=$(( $(date +%s) - fresh ))
if (( age <= stale_threshold )); then pass "fresh heartbeat is not stale (age=$age <= $stale_threshold)"
else fail "false stale positive" "age=$age"; fi

rm -rf "$TC_LOG_DIR" "$TC_RUN_DIR"
finish_suite
