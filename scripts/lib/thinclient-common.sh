#!/usr/bin/env bash
# =============================================================================
#  ThinClient OS — Common shell library
#  Installed to: /opt/thinclient/lib/thinclient-common.sh
#
#  Sourced by every ThinClient script. Provides:
#    * Canonical paths
#    * Structured logging with rotation-friendly output
#    * A SAFE config reader (does NOT `source` untrusted files)
#    * Boolean normalization and validation helpers
#
#  This file is intentionally dependency-light: pure Bash + coreutils only.
# =============================================================================

# Guard against double-sourcing.
[[ -n "${__THINCLIENT_COMMON_SOURCED:-}" ]] && return 0
__THINCLIENT_COMMON_SOURCED=1

# ----------------------------------------------------------------------------
# Canonical paths (override via environment for testing).
# ----------------------------------------------------------------------------
: "${TC_PREFIX:=/opt/thinclient}"
: "${TC_ETC:=/etc/thinclient}"
: "${TC_CONF:=${TC_ETC}/server.conf}"
: "${TC_ADMIN_CONF:=${TC_ETC}/admin.conf}"
: "${TC_LOG_DIR:=/var/log/thinclient}"
: "${TC_RUN_DIR:=/run/thinclient}"
: "${TC_STATE_FILE:=${TC_RUN_DIR}/state}"
: "${TC_HEARTBEAT_FILE:=${TC_RUN_DIR}/heartbeat}"

# ----------------------------------------------------------------------------
# Logging.
#   tc_log <logfile-basename> <LEVEL> <message...>
#   Writes an ISO-8601 timestamped line to both the named log and stderr.
# ----------------------------------------------------------------------------
tc_log() {
  local logname="$1"; shift
  local level="$1"; shift
  local ts msg line
  ts="$(date --iso-8601=seconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z')"
  msg="$*"
  line="${ts} [${level}] ${msg}"
  # Best-effort: never let logging failure kill the caller.
  if [[ -d "$TC_LOG_DIR" ]] && { [[ -w "$TC_LOG_DIR" ]] || [[ -w "${TC_LOG_DIR}/${logname}.log" ]]; }; then
    printf '%s\n' "$line" >>"${TC_LOG_DIR}/${logname}.log" 2>/dev/null || true
  fi
  printf '%s\n' "$line" >&2
}

log_info()  { tc_log "${TC_LOGFILE:-thinclient}" "INFO"  "$@"; }
log_warn()  { tc_log "${TC_LOGFILE:-thinclient}" "WARN"  "$@"; }
log_error() { tc_log "${TC_LOGFILE:-thinclient}" "ERROR" "$@"; }
log_debug() { [[ "${TC_DEBUG:-0}" == "1" ]] && tc_log "${TC_LOGFILE:-thinclient}" "DEBUG" "$@"; return 0; }

# ----------------------------------------------------------------------------
# Boolean normalization.
#   tc_bool <value>  -> echoes "true" or "false", returns 0/1 accordingly.
# ----------------------------------------------------------------------------
tc_bool() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" in
    1|true|yes|on|enable|enabled)   echo "true";  return 0 ;;
    *)                              echo "false"; return 1 ;;
  esac
}

# tc_is_true <value> -> exit 0 if truthy, else 1. No output.
tc_is_true() { [[ "$(tc_bool "$1")" == "true" ]]; }

# ----------------------------------------------------------------------------
# SAFE config reader.
#   tc_conf_get <file> <KEY> [default]
#   Reads a single KEY=VALUE line without executing the file. Strips inline
#   surrounding quotes and trailing comments/whitespace. Only [A-Za-z0-9_]
#   keys are honored, so a malicious file cannot inject shell.
# ----------------------------------------------------------------------------
tc_conf_get() {
  local file="$1" key="$2" default="${3:-}" val
  [[ -r "$file" ]] || { printf '%s' "$default"; return 0; }
  # Last matching assignment wins. Ignore commented and malformed lines.
  val="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$file" 2>/dev/null \
          | grep -Ev '^[[:space:]]*#' \
          | tail -n1 \
          | sed -E "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//")"
  if [[ -z "$val" && -z "$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$file" 2>/dev/null | grep -Ev '^[[:space:]]*#')" ]]; then
    printf '%s' "$default"; return 0
  fi
  # Strip a single pair of surrounding quotes if present.
  if [[ "$val" =~ ^\"(.*)\"$ ]]; then
    val="${BASH_REMATCH[1]}"
  elif [[ "$val" =~ ^\'(.*)\'$ ]]; then
    val="${BASH_REMATCH[1]}"
  else
    # Unquoted: trim a trailing inline comment and surrounding whitespace.
    val="${val%%#*}"
    val="${val%"${val##*[![:space:]]}"}"
  fi
  printf '%s' "$val"
}

# Convenience wrappers bound to the primary config file.
conf_get()  { tc_conf_get "$TC_CONF" "$@"; }
admin_get() { tc_conf_get "$TC_ADMIN_CONF" "$@"; }

# ----------------------------------------------------------------------------
# Validation helpers.
# ----------------------------------------------------------------------------
tc_is_valid_host() {
  local h="$1"
  [[ -n "$h" ]] || return 1
  # Accept IPv4, or a DNS hostname/FQDN. Reject shell metacharacters.
  [[ "$h" =~ ^[A-Za-z0-9._-]+$ ]]
}

tc_is_valid_port() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 ))
}

# tc_have_network — return 0 if the box can leave its subnet (has a default
# route), else consult NetworkManager's own connectivity verdict. Used by the
# network gate to decide whether to show the WiFi picker.
tc_have_network() {
  if ip route show default 2>/dev/null | grep -q .; then
    return 0
  fi
  if command -v nmcli >/dev/null 2>&1; then
    case "$(nmcli -t -f CONNECTIVITY general status 2>/dev/null)" in
      full|limited|portal) return 0 ;;
    esac
  fi
  return 1
}

# tc_require_cmd <cmd...> — log & fail if any command is missing.
tc_require_cmd() {
  local missing=0 c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || { log_error "Required command not found: $c"; missing=1; }
  done
  return $missing
}

# ----------------------------------------------------------------------------
# Runtime state helpers (for watchdog / status reporting).
# ----------------------------------------------------------------------------
tc_set_state() {
  mkdir -p "$TC_RUN_DIR" 2>/dev/null || true
  printf '%s\n' "$1" >"$TC_STATE_FILE" 2>/dev/null || true
}
tc_get_state() { cat "$TC_STATE_FILE" 2>/dev/null || echo "UNKNOWN"; }
tc_heartbeat() {
  mkdir -p "$TC_RUN_DIR" 2>/dev/null || true
  date +%s >"$TC_HEARTBEAT_FILE" 2>/dev/null || true
}
