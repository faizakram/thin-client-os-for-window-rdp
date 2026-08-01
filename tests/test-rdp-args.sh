#!/usr/bin/env bash
# =============================================================================
#  Unit tests — FreeRDP argument generation from server.conf
#  Validates the mapping AND the security property that the password never
#  lands in argv.
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
export CURRENT_SUITE="rdp-args"
source "$HERE/test-helpers.sh"

export TC_LOG_DIR="$(mktemp -d)"
export TC_RUN_DIR="$(mktemp -d)"
export TC_CONF="$HERE/mock/server.conf"
unset DISPLAY   # force single-monitor path (no xrandr)
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/rdp-build-args.sh"

tc_build_rdp_args
ARGS="${TC_RDP_ARGS[*]}"
echo "Generated: xfreerdp3 ${ARGS}"
echo

echo "== connection =="
assert_contains "$ARGS" "/v:10.20.30.40:3389" "target host:port"
assert_contains "$ARGS" "/u:developer"        "username flag"
assert_contains "$ARGS" "/d:CORP"             "domain flag"
assert_contains "$ARGS" "/from-stdin:force"   "password read from stdin (not argv)"

echo "== security: password is NOT in argv =="
assert_not_contains "$ARGS" "s3cr3t-pass" "plaintext password absent from argv"
assert_not_contains "$ARGS" "/p:"          "no /p: flag present"
assert_eq "s3cr3t-pass" "$TC_RDP_PASSWORD"  "password captured separately for stdin"

echo "== display (single monitor -> fullscreen) =="
assert_contains "$ARGS" "/f"                  "fullscreen when one monitor"
assert_contains "$ARGS" "/dynamic-resolution" "dynamic resolution enabled"

echo "== device redirection =="
assert_contains "$ARGS" "/clipboard"          "clipboard on"
assert_contains "$ARGS" "/sound:sys:pulse"    "speakers on"
assert_contains "$ARGS" "/microphone:sys:pulse" "microphone on"
assert_contains "$ARGS" "/video"              "camera on"
assert_not_contains "$ARGS" "/usb:auto"       "usb off (per config)"
assert_not_contains "$ARGS" "/printer"        "printer off (per config)"

echo "== performance / security flags =="
assert_contains "$ARGS" "/gfx:AVC444"         "GPU H.264 pipeline"
assert_contains "$ARGS" "/cache:bitmap:on,glyph:on"  "bitmap/glyph cache (FreeRDP-3 syntax)"
assert_contains "$ARGS" "/network:lan"        "network profile mapped"
assert_contains "$ARGS" "/sec:nla"            "NLA security"
assert_contains "$ARGS" "/cert:tofu"          "trust-on-first-use cert policy"
assert_contains "$ARGS" "/auto-reconnect"     "freerdp auto-reconnect"
assert_contains "$ARGS" "/timeout:20000"      "EXTRA_ARGS appended verbatim"
assert_contains "$ARGS" "-grab-keyboard"      "keyboard grab disabled (no breakout)"

echo "== multi-monitor path =="
# Simulate two connected outputs by shadowing xrandr.
xrandr() { printf '%s\n' "Screen 0: ..." "HDMI-1 connected 1920x1080" "HDMI-2 connected 1920x1080"; }
export -f xrandr
export DISPLAY=:0
tc_build_rdp_args
MARGS="${TC_RDP_ARGS[*]}"
assert_contains "$MARGS" "/multimon" "uses /multimon when >1 output present"
unset -f xrandr; unset DISPLAY

echo "== invalid config is rejected =="
badconf="$(mktemp)"; echo "SERVER_IP=bad;host" >"$badconf"
assert_false bash -c "TC_CONF='$badconf'; source '$ROOT/scripts/lib/rdp-build-args.sh'; tc_build_rdp_args" \
  "build fails on invalid SERVER_IP"
rm -f "$badconf"

rm -rf "$TC_LOG_DIR" "$TC_RUN_DIR"
finish_suite
