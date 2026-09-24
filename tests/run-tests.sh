#!/usr/bin/env bash
# =============================================================================
#  ThinClient OS — Test runner
#  Runs shellcheck lint + all unit suites. Returns non-zero if anything fails.
#  Intended for CI and the Docker `tester` service (make test).
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

blue=$'\033[1;34m'; green=$'\033[1;32m'; red=$'\033[1;31m'; off=$'\033[0m'
banner() { printf '\n%s========== %s ==========%s\n' "$blue" "$1" "$off"; }

fail_total=0

# --- Lint --------------------------------------------------------------------
banner "shellcheck lint"
if bash "$HERE/lint.sh"; then
  printf '%slint OK%s\n' "$green" "$off"
else
  printf '%slint FAILED%s\n' "$red" "$off"; fail_total=$((fail_total+1))
fi

# --- Unit suites -------------------------------------------------------------
for suite in test-config-parsing test-config-cli test-rdp-args test-watchdog test-admin-auth test-installer-reachability test-installer-disk-release test-iso-naming; do
  banner "$suite"
  if bash "$HERE/${suite}.sh"; then :; else fail_total=$((fail_total+1)); fi
done


# --- python unit suites ------------------------------------------------------
# Activity-state recovery: the agent used to lose an RDP_DISCONNECT across every
# reboot, which corrupted working-hours reporting fleet-wide.
banner "test-activity-state"
if python3 "$HERE/test-activity-state.py"; then :; else fail_total=$((fail_total+1)); fi

banner "test-camera-format"
if python3 "$HERE/test-camera-format.py"; then :; else fail_total=$((fail_total+1)); fi

echo "== camera USB drop / recovery =="
if python3 "$HERE/test-camera-recovery.py"; then :; else fail_total=$((fail_total+1)); fi

banner "test-lock-chat"
if python3 "$HERE/test-lock-chat.py"; then :; else fail_total=$((fail_total+1)); fi

# --- static guards added after live failures --------------------------------
# A non-ASCII character in a GTK CSS blob that gets .encode("ascii") kills the GUI
# app at import — that is how the chat panel vanished from a live device.
if bash "$HERE/check-gui-ascii.sh"; then :; else fail_total=$((fail_total+1)); fi
banner "summary"
if (( fail_total == 0 )); then
  printf '%sALL TEST SUITES PASSED%s\n' "$green" "$off"; exit 0
else
  printf '%s%d SUITE(S) FAILED%s\n' "$red" "$fail_total" "$off"; exit 1
fi
