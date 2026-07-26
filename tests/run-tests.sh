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
for suite in test-config-parsing test-config-cli test-rdp-args test-watchdog test-admin-auth; do
  banner "$suite"
  if bash "$HERE/${suite}.sh"; then :; else fail_total=$((fail_total+1)); fi
done

banner "summary"
if (( fail_total == 0 )); then
  printf '%sALL TEST SUITES PASSED%s\n' "$green" "$off"; exit 0
else
  printf '%s%d SUITE(S) FAILED%s\n' "$red" "$fail_total" "$off"; exit 1
fi
