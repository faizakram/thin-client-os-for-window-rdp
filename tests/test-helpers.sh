#!/usr/bin/env bash
# =============================================================================
#  ThinClient OS — Tiny test harness (assertions + counters)
#  Sourced by every tests/test-*.sh script.
# =============================================================================
set -uo pipefail

TESTS_RUN=0
TESTS_FAILED=0
: "${CURRENT_SUITE:=tests}"

_green=$'\033[1;32m'; _red=$'\033[1;31m'; _dim=$'\033[2m'; _off=$'\033[0m'

pass() { TESTS_RUN=$((TESTS_RUN+1)); printf '  %s✓%s %s\n' "$_green" "$_off" "$1"; }
fail() {
  TESTS_RUN=$((TESTS_RUN+1)); TESTS_FAILED=$((TESTS_FAILED+1))
  printf '  %s✗%s %s\n' "$_red" "$_off" "$1"
  [[ -n "${2:-}" ]] && printf '      %s%s%s\n' "$_dim" "$2" "$_off"
}

# assert_eq <expected> <actual> <message>
assert_eq() {
  if [[ "$1" == "$2" ]]; then pass "$3"
  else fail "$3" "expected='$1' actual='$2'"; fi
}

# assert_contains <haystack> <needle> <message>
assert_contains() {
  if [[ "$1" == *"$2"* ]]; then pass "$3"
  else fail "$3" "needle '$2' not found in: $1"; fi
}

# assert_not_contains <haystack> <needle> <message>
assert_not_contains() {
  if [[ "$1" != *"$2"* ]]; then pass "$3"
  else fail "$3" "unexpected needle '$2' found in: $1"; fi
}

# assert_true <cmd...> — passes if the command succeeds.
assert_true() {
  local msg="${!#}"; set -- "${@:1:$#-1}"
  if "$@" >/dev/null 2>&1; then pass "$msg"; else fail "$msg" "command failed: $*"; fi
}

# assert_false <cmd...> — passes if the command fails.
assert_false() {
  local msg="${!#}"; set -- "${@:1:$#-1}"
  if ! "$@" >/dev/null 2>&1; then pass "$msg"; else fail "$msg" "command unexpectedly succeeded: $*"; fi
}

finish_suite() {
  echo
  if (( TESTS_FAILED == 0 )); then
    printf '%s[%s] %d passed%s\n' "$_green" "$CURRENT_SUITE" "$TESTS_RUN" "$_off"
    exit 0
  else
    printf '%s[%s] %d/%d failed%s\n' "$_red" "$CURRENT_SUITE" "$TESTS_FAILED" "$TESTS_RUN" "$_off"
    exit 1
  fi
}
