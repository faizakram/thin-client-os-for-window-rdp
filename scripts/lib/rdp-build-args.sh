#!/usr/bin/env bash
# =============================================================================
#  ThinClient OS — FreeRDP command builder
#  Installed to: /opt/thinclient/lib/rdp-build-args.sh
#
#  Translates /etc/thinclient/server.conf into a validated argv array for
#  xfreerdp3. Kept separate from the launcher so it can be unit-tested in
#  isolation (see tests/test-rdp-args.sh) without opening a display.
#
#  Contract:
#    tc_build_rdp_args   -> populates the global array  TC_RDP_ARGS
#                           and sets  TC_RDP_PASSWORD  (may be empty).
#    Returns 0 on success, non-zero (with a logged reason) on bad config.
#
#  SECURITY: the password is deliberately NOT placed in TC_RDP_ARGS. The
#  launcher feeds it to xfreerdp via stdin (/from-stdin) so it never appears
#  in `ps` output or any process listing.
# =============================================================================

# Resolve library directory and pull in common helpers.
__RDP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${__RDP_LIB_DIR}/thinclient-common.sh"

# Detect the FreeRDP 3 binary. Prefer xfreerdp3, fall back to xfreerdp.
tc_rdp_binary() {
  if command -v xfreerdp3 >/dev/null 2>&1; then echo "xfreerdp3"
  elif command -v xfreerdp >/dev/null 2>&1; then echo "xfreerdp"
  else return 1; fi
}

# Map NETWORK_PROFILE -> FreeRDP /network flag value.
__tc_network_flag() {
  case "$(printf '%s' "${1:-auto}" | tr '[:upper:]' '[:lower:]')" in
    modem)              echo "modem" ;;
    broadband)          echo "broadband-high" ;;
    wan)                echo "wan" ;;
    lan)                echo "lan" ;;
    auto|autodetect|*)  echo "auto" ;;
  esac
}

# Main builder. Populates TC_RDP_ARGS (array) and TC_RDP_PASSWORD (string).
tc_build_rdp_args() {
  TC_RDP_ARGS=()
  TC_RDP_PASSWORD=""

  # ---- Read + validate connection basics -----------------------------------
  local server port user domain password
  server="$(conf_get SERVER_IP)"
  port="$(conf_get PORT 3389)"
  user="$(conf_get USERNAME)"
  domain="$(conf_get DOMAIN)"
  password="$(conf_get PASSWORD)"

  if ! tc_is_valid_host "$server"; then
    log_error "Invalid or missing SERVER_IP in ${TC_CONF}: '${server}'"
    return 2
  fi
  if ! tc_is_valid_port "$port"; then
    log_warn "Invalid PORT '${port}', defaulting to 3389"
    port=3389
  fi

  TC_RDP_ARGS+=( "/v:${server}:${port}" )
  [[ -n "$user"   ]] && TC_RDP_ARGS+=( "/u:${user}" )
  [[ -n "$domain" ]] && TC_RDP_ARGS+=( "/d:${domain}" )
  TC_RDP_PASSWORD="$password"
  # Read remaining creds (i.e. the password) from stdin instead of argv.
  TC_RDP_ARGS+=( "/from-stdin:force" )

  # ---- Display -------------------------------------------------------------
  local fullscreen multimon dynres
  fullscreen="$(tc_bool "$(conf_get FULLSCREEN true)")"
  multimon="$(tc_bool "$(conf_get MULTIMONITOR true)")"
  dynres="$(tc_bool "$(conf_get DYNAMIC_RESOLUTION true)")"

  # Count connected outputs, if we can, to decide multimon vs single fullscreen.
  local outputs=1
  if command -v xrandr >/dev/null 2>&1 && [[ -n "${DISPLAY:-}" ]]; then
    outputs="$(xrandr --query 2>/dev/null | grep -c ' connected' || echo 1)"
    [[ "$outputs" =~ ^[0-9]+$ ]] || outputs=1
  fi

  if [[ "$multimon" == "true" && "$outputs" -gt 1 ]]; then
    TC_RDP_ARGS+=( "/multimon" )
  elif [[ "$fullscreen" == "true" ]]; then
    TC_RDP_ARGS+=( "/f" )
  fi
  [[ "$dynres" == "true" ]] && TC_RDP_ARGS+=( "/dynamic-resolution" )

  # ---- Device redirection --------------------------------------------------
  tc_is_true "$(conf_get CLIPBOARD true)"  && TC_RDP_ARGS+=( "/clipboard" )
  tc_is_true "$(conf_get SPEAKERS true)"   && TC_RDP_ARGS+=( "/sound:sys:pulse" )
  tc_is_true "$(conf_get MICROPHONE true)" && TC_RDP_ARGS+=( "/microphone:sys:pulse" )
  tc_is_true "$(conf_get CAMERA false)"    && TC_RDP_ARGS+=( "/video" )
  tc_is_true "$(conf_get USB false)"       && TC_RDP_ARGS+=( "/usb:auto" )
  tc_is_true "$(conf_get PRINTER false)"   && TC_RDP_ARGS+=( "/printer" )
  tc_is_true "$(conf_get SMARTCARD false)" && TC_RDP_ARGS+=( "/smartcard" )

  # ---- Performance / visuals ----------------------------------------------
  if tc_is_true "$(conf_get GPU true)"; then
    # Hardware path: server-side H.264 GFX pipeline. /gfx:AVC444 already selects
    # the H.264/AVC444 codec — the old "+gfx-h264" toggle was removed in FreeRDP 3.
    TC_RDP_ARGS+=( "/gfx:AVC444" )
  fi
  # No-GPU path: pass NO /gfx flag at all. FreeRDP then uses legacy graphics
  # (bitmap/RemoteFX negotiation) which render on any framebuffer, including a
  # basic nomodeset/fbdev X server. (There is no "-gfx" toggle in FreeRDP; that
  # is an invalid argument that makes xfreerdp exit before connecting.)
  # FreeRDP 3 folded the bitmap/glyph caches into /cache: ; the FreeRDP-2
  # "+bitmap-cache"/"+glyph-cache" names are rejected as "Unexpected keyword".
  tc_is_true "$(conf_get BITMAP_CACHE true)"        && TC_RDP_ARGS+=( "/cache:bitmap:on,glyph:on" )
  # DESKTOP_COMPOSITION (+aero) is heavy for a kiosk and off by default; omit it.
  tc_is_true "$(conf_get FONT_SMOOTHING true)"      && TC_RDP_ARGS+=( "+fonts" )
  TC_RDP_ARGS+=( "/network:$(__tc_network_flag "$(conf_get NETWORK_PROFILE auto)")" )
  # Verbose FreeRDP logging so any connection failure reason lands in rdp.log.
  TC_RDP_ARGS+=( "/log-level:INFO" )

  # ---- Security ------------------------------------------------------------
  case "$(printf '%s' "$(conf_get SECURITY nla)" | tr '[:upper:]' '[:lower:]')" in
    tls) TC_RDP_ARGS+=( "/sec:tls" ) ;;
    rdp) TC_RDP_ARGS+=( "/sec:rdp" ) ;;
    *)   TC_RDP_ARGS+=( "/sec:nla" ) ;;
  esac
  case "$(printf '%s' "$(conf_get CERT_POLICY tofu)" | tr '[:upper:]' '[:lower:]')" in
    ignore) TC_RDP_ARGS+=( "/cert:ignore" ) ;;
    *)      TC_RDP_ARGS+=( "/cert:tofu" ) ;;
  esac

  # ---- Reconnect / resilience ---------------------------------------------
  # FreeRDP's own auto-reconnect complements the launcher's outer loop.
  TC_RDP_ARGS+=( "/auto-reconnect" "/auto-reconnect-max-retries:0" )
  # Reasonable connect timeout so a dead server fails fast into the retry loop.
  TC_RDP_ARGS+=( "/timeout:15000" )

  # ---- Kiosk hardening -----------------------------------------------------
  # No local window decorations / menu; keep title minimal; disable the
  # FreeRDP-side keyboard grab escape so users cannot break out.
  TC_RDP_ARGS+=( "-grab-keyboard" "/floatbar:sticky:off,default:hidden" "/t:Remote Workspace" )

  # ---- Extra raw args ------------------------------------------------------
  local extra
  extra="$(conf_get EXTRA_ARGS)"
  if [[ -n "$extra" ]]; then
    # shellcheck disable=SC2206
    local -a extra_arr=( $extra )
    TC_RDP_ARGS+=( "${extra_arr[@]}" )
  fi

  return 0
}

# Debug/preview helper: print the command that WOULD run (password redacted).
tc_print_rdp_command() {
  local bin
  bin="$(tc_rdp_binary)" || { echo "(no FreeRDP binary found)"; return 1; }
  tc_build_rdp_args || return $?
  printf '%s' "$bin"
  local a
  for a in "${TC_RDP_ARGS[@]}"; do printf ' %q' "$a"; done
  if [[ -n "$TC_RDP_PASSWORD" ]]; then printf '   # (password supplied via stdin)'; fi
  printf '\n'
}
