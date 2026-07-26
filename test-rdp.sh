#!/usr/bin/env bash
# =============================================================================
#  ThinClient OS — Real RDP server test
#
#  Reads the configuration (or env vars) and probes a LIVE Windows RDP server:
#    1. Verifies TCP connectivity to host:port
#    2. Validates RDP authentication where possible (FreeRDP /auth-only)
#    3. Optionally opens a real windowed FreeRDP session for a manual eyeball
#    4. Writes detailed logs and reports success/failure with diagnostics
#
#  Credentials are NEVER hardcoded here — they come from:
#    * /etc/thinclient/server.conf on the appliance, OR
#    * ./config/server.conf in this repo (for desktop testing), OR
#    * environment variables (override anything): TC_SERVER, TC_PORT,
#      TC_USER, TC_PASSWORD, TC_DOMAIN
#
#  Usage:
#     ./test-rdp.sh                # probe only (TCP + auth)
#     ./test-rdp.sh --session      # also open a real FreeRDP window (needs X)
# =============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Use the appliance config if present, else the repo config.
if [[ -r /etc/thinclient/server.conf ]]; then
  export TC_CONF="/etc/thinclient/server.conf"
else
  export TC_CONF="${TC_CONF:-$ROOT/config/server.conf}"
fi
export TC_LIB_DIR="${TC_LIB_DIR:-$ROOT/scripts/lib}"
export TC_LOG_DIR="${TC_LOG_DIR:-${TMPDIR:-/tmp}/thinclient-logs}"
export TC_RUN_DIR="${TC_RUN_DIR:-${TMPDIR:-/tmp}/thinclient-run}"
mkdir -p "$TC_LOG_DIR" "$TC_RUN_DIR"

# shellcheck source=/dev/null
source "$TC_LIB_DIR/thinclient-common.sh"

# Allow env-var overrides (handy for CI / ad-hoc testing without editing files).
apply_overrides() {
  local tmp; tmp="$(mktemp)"; cp "$TC_CONF" "$tmp" 2>/dev/null || : >"$tmp"
  export TC_CONF="$tmp"
  [[ -n "${TC_SERVER:-}"   ]] && "$ROOT/scripts/thinclient-config" set SERVER_IP "$TC_SERVER" >/dev/null
  [[ -n "${TC_PORT:-}"     ]] && "$ROOT/scripts/thinclient-config" set PORT       "$TC_PORT"   >/dev/null
  [[ -n "${TC_USER:-}"     ]] && "$ROOT/scripts/thinclient-config" set USERNAME   "$TC_USER"   >/dev/null
  [[ -n "${TC_PASSWORD:-}" ]] && "$ROOT/scripts/thinclient-config" set PASSWORD   "$TC_PASSWORD" >/dev/null
  [[ -n "${TC_DOMAIN:-}"   ]] && "$ROOT/scripts/thinclient-config" set DOMAIN     "$TC_DOMAIN" >/dev/null
}
apply_overrides

echo "Config source : ${TC_CONF}"
echo "Log directory : ${TC_LOG_DIR}"
echo

# --- 1 & 2: connectivity + auth probe (shared with the appliance) ------------
# Reuse the exact same probe the appliance's Admin panel uses.
TC_LIB_DIR="$TC_LIB_DIR" TC_CONF="$TC_CONF" "$ROOT/scripts/thinclient-test-connection"
probe_rc=$?

# --- 3: optional real session ------------------------------------------------
if [[ "${1:-}" == "--session" ]]; then
  echo
  if [[ -z "${DISPLAY:-}" ]]; then
    echo "[skip] --session requested but no X DISPLAY is available."
  else
    echo "Opening a real FreeRDP window (close it to end the test)..."
    # shellcheck source=/dev/null
    source "$TC_LIB_DIR/rdp-build-args.sh"
    if tc_build_rdp_args; then
      bin="$(tc_rdp_binary)"
      # Windowed (not fullscreen) for a manual test so it is easy to close.
      filtered=(); for a in "${TC_RDP_ARGS[@]}"; do [[ "$a" == "/f" || "$a" == "/multimon" ]] || filtered+=("$a"); done
      if [[ -n "$TC_RDP_PASSWORD" ]]; then
        printf '%s\n' "$TC_RDP_PASSWORD" | "$bin" "${filtered[@]}" /size:1280x800
      else
        "$bin" "${filtered[@]}" /size:1280x800
      fi
    fi
  fi
fi

echo
case "$probe_rc" in
  0) echo "OVERALL: SUCCESS" ;;
  1) echo "OVERALL: reachable but authentication failed — check credentials." ;;
  2) echo "OVERALL: server unreachable — check network/firewall/RDP enabled." ;;
  *) echo "OVERALL: configuration problem — run: scripts/thinclient-config validate" ;;
esac
exit "$probe_rc"
