#!/usr/bin/env bash
# =============================================================================
#  Unit tests — the installer's "can I reach the manager?" gate.
#
#  This block decides whether a disk gets erased, so every branch is exercised
#  here rather than discovered on a machine in front of a customer:
#
#    * an unreachable manager must never silently proceed, and must never look
#      frozen (it printed nothing for ~3 minutes, which is what made an operator
#      photograph it believing the installer had hung);
#    * the operator may choose to install anyway — that grants nothing, because
#      the machine still has to ask to join and still has to be approved;
#    * anything other than an explicit yes means NO;
#    * when the tenant does not require approval, the install continues on its
#      own with no prompt at all.
#
#  The block is extracted from installer/install-to-disk.sh and run with every
#  external command stubbed, so the real script is the thing under test — not a
#  copy of it that can drift.
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
export CURRENT_SUITE="installer-reachability"
source "$HERE/test-helpers.sh"

SRC="$ROOT/installer/install-to-disk.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A stub enrol binary whose exit code the tests choose.
mkdir -p "$WORK/bin"
printf '#!/bin/sh\necho ENROLL_BIN_RAN\nexit ${ENROLL_EXIT:-0}\n' > "$WORK/bin/thinclient-enroll"
chmod +x "$WORK/bin/thinclient-enroll"

# Extract the real section: the tenant-token gate through to its closing fi.
python3 - "$SRC" "$WORK/section.sh" "$WORK/bin/thinclient-enroll" <<'PY'
import io, sys
src, out, stub = sys.argv[1], sys.argv[2], sys.argv[3]
t = io.open(src, encoding="utf-8").read()
start = t.index('if [[ -n "$CTRL_URL" && -n "$TEN_TOKEN" ]]; then')
end   = t.index('# 2. Partition + format.')
sec   = t[start:t.rindex('fi', start, end) + 2]
# Record whether the enrol binary ran, and point it at the stub.
sec = sec.replace('"$ENROLL_BIN" --url', 'ENROLL_RAN=1; "$ENROLL_BIN" --url')
sec = sec.replace('ENROLL_BIN="/opt/thinclient/bin/thinclient-enroll"',
                  'ENROLL_BIN="%s"' % stub)
# Answers arrive on stdin in the harness; the real script prefers the console.
sec = sec.replace('[[ -r /dev/tty ]]', 'false')
io.open(out, "w").write('''#!/usr/bin/env bash
set -uo pipefail
CTRL_URL="https://m.example.com"; TEN_TOKEN="tok"; DISK="/dev/sdX"
DEVICE_HWID="abc"; DEVNAME="user37"; ENROLL_CREDS=""; ENROLL_RAN=0
log(){ printf '[install] %s\\n' "$*"; }
warn(){ printf '[!] %s\\n' "$*"; }
ok(){ printf '[OK] %s\\n' "$*"; }
curl(){ return "${CURL_RC:-7}"; }      # 7 = could not connect
timeout(){ shift; "$@"; }
sleep(){ :; }; ip(){ :; }; getent(){ return 1; }; hostname(){ echo host; }
mktemp(){ echo "$WORK/creds"; }
''' + sec + '''
echo "REACHED_PARTITIONING enroll_ran=$ENROLL_RAN"
''')
PY
export WORK

run() {   # run <stdin-answer> [env...]; echoes output, sets RC
  local answer="$1"; shift
  OUT="$(printf '%s\n' "$answer" | env "$@" bash "$WORK/section.sh" 2>&1)"; RC=$?
}

echo "== unreachable manager: the operator declines =="
run "n"
assert_eq "1" "$RC" "declining aborts the install"
assert_not_contains "$OUT" "REACHED_PARTITIONING" "the disk is never partitioned"
assert_contains "$OUT" "untouched" "the operator is told the disk is untouched"

echo
echo "== it must never look frozen =="
assert_contains "$OUT" "attempt 1 of 12" "the first attempt is announced"
assert_contains "$OUT" "attempt 12 of 12" "and so is the last"
COUNT="$(grep -c 'attempt .* of 12' <<<"$OUT")"
assert_eq "12" "$COUNT" "every attempt reports, so silence never reads as a hang"

echo
echo "== unreachable manager: the operator installs anyway =="
run "y"
assert_eq "0" "$RC" "accepting continues the install"
assert_contains "$OUT" "REACHED_PARTITIONING" "the install proceeds"
assert_contains "$OUT" "Skipping the approval step" "and says why it skipped approval"
assert_not_contains "$OUT" "ENROLL_BIN_RAN" "enrolment is not attempted with no network"
assert_contains "$OUT" "must be approved later" "the operator is warned approval still applies"
run "yes"
assert_eq "0" "$RC" "'yes' spelled out is accepted too"

echo
echo "== only an explicit yes counts =="
run ""
assert_eq "1" "$RC" "a bare Enter declines"
run "maybe"
assert_eq "1" "$RC" "an unrecognised answer declines"

echo
echo "== manager reachable =="
run "" CURL_RC=0
assert_eq "0" "$RC" "a reachable manager proceeds"
assert_not_contains "$OUT" "Install anyway" "and asks the operator nothing"
assert_not_contains "$OUT" "attempt 1 of 12" "and does not report retries it never made"

echo
echo "== the tenant does not require approval =="
run "" CURL_RC=0 ENROLL_EXIT=3
assert_eq "0" "$RC" "the install continues with no approval"
assert_contains "$OUT" "does not require approval" "and says so"
assert_contains "$OUT" "REACHED_PARTITIONING" "and reaches partitioning"

echo
echo "== the machine was refused =="
run "" CURL_RC=0 ENROLL_EXIT=1
assert_eq "1" "$RC" "a refused machine does not install"
assert_not_contains "$OUT" "REACHED_PARTITIONING" "and its disk is left alone"

finish_suite
