#!/usr/bin/env bash
# =============================================================================
#  ThinClient OS — ISO builder
#
#  Produces  iso/thinclient.iso  — a hybrid BIOS+UEFI bootable Debian 13
#  (Trixie) live image that boots straight into the locked-down FreeRDP kiosk.
#
#  Usage:
#     sudo ./build.sh              # full build
#     sudo ./build.sh --clean      # remove previous build artifacts first
#     sudo ./build.sh --rebuild    # clean + build
#
#  Requirements (Debian/Ubuntu host, or the provided Docker builder):
#     * live-build, debootstrap, xorriso, and root privileges
#     * ~8 GB free disk and a working internet connection to a Debian mirror
#
#  On macOS/Windows use the Docker builder instead:  make iso   (see docker/)
# =============================================================================
set -euo pipefail

# --------------------------------------------------------------------------- #
# Configuration (override via environment).
# --------------------------------------------------------------------------- #
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST="${TC_DIST:-trixie}"
ARCH="${TC_ARCH:-amd64}"
MIRROR="${TC_MIRROR:-http://deb.debian.org/debian/}"
BUILD_DIR="${TC_BUILD_DIR:-${PROJECT_ROOT}/build/live-build}"
OUTPUT_ISO="${PROJECT_ROOT}/iso/thinclient.iso"
VERSION="${TC_VERSION:-1.0.0}"

BOOTAPPEND="boot=live components \
live-config.username=thinclient live-config.hostname=thinclient live-config.noautologin \
quiet splash loglevel=0 vt.global_cursor_default=0 \
rd.systemd.show_status=false systemd.show_status=false udev.log_level=0"

# Arch-specific bootloader + image type. amd64 gets a BIOS+UEFI hybrid ISO;
# arm64 (UEFI-only platform) gets a plain UEFI ISO with grub-efi.
if [[ "$ARCH" == "amd64" || "$ARCH" == "i386" ]]; then
  BOOTLOADERS="grub-efi grub-pc"
  BINARY_IMAGES="iso-hybrid"
else
  BOOTLOADERS="grub-efi"
  BINARY_IMAGES="iso"
fi

# --------------------------------------------------------------------------- #
# Pretty logging.
# --------------------------------------------------------------------------- #
c_blue=$'\033[1;34m'; c_green=$'\033[1;32m'; c_red=$'\033[1;31m'; c_yellow=$'\033[1;33m'; c_off=$'\033[0m'
say()  { printf '%s==>%s %s\n' "$c_blue"  "$c_off" "$*"; }
ok()   { printf '%s[OK]%s %s\n' "$c_green" "$c_off" "$*"; }
warn() { printf '%s[!]%s %s\n'  "$c_yellow" "$c_off" "$*" >&2; }
die()  { printf '%s[x]%s %s\n'  "$c_red"   "$c_off" "$*" >&2; exit 1; }

# --------------------------------------------------------------------------- #
# Preconditions.
# --------------------------------------------------------------------------- #
preflight() {
  say "Pre-flight checks"
  [[ "$(id -u)" -eq 0 ]] || die "build.sh must run as root (use: sudo ./build.sh). Non-Linux hosts: use the Docker builder (make iso)."
  [[ "$(uname -s)" == "Linux" ]] || die "live-build only runs on Linux. On macOS/Windows use: make iso  (Docker builder)."
  command -v lb >/dev/null 2>&1 || die "live-build not installed. Install with: apt-get install -y live-build"
  command -v debootstrap >/dev/null 2>&1 || die "debootstrap not installed. Install with: apt-get install -y debootstrap"
  command -v xorriso >/dev/null 2>&1 || warn "xorriso not found; live-build may fail to emit the ISO. apt-get install -y xorriso"
  local free_kb; free_kb="$(df -Pk "$PROJECT_ROOT" | awk 'NR==2{print $4}')"
  (( free_kb > 8000000 )) || warn "Less than ~8 GB free at $PROJECT_ROOT; the build may run out of space."
  ok "Environment looks good (dist=${DIST} arch=${ARCH})"
}

# --------------------------------------------------------------------------- #
# Stage a repo file into the target rootfs (config/includes.chroot).
#   stage <src-relative> <dest-absolute-in-target> [mode]
# --------------------------------------------------------------------------- #
stage() {
  local src="${PROJECT_ROOT}/$1" dest="$2" mode="${3:-0644}"
  local target="${BUILD_DIR}/config/includes.chroot${dest}"
  [[ -e "$src" ]] || die "stage: missing source $src"
  install -D -m "$mode" "$src" "$target"
}

# --------------------------------------------------------------------------- #
# Clean.
# --------------------------------------------------------------------------- #
do_clean() {
  say "Cleaning previous build artifacts"
  if [[ -d "$BUILD_DIR" ]]; then
    ( cd "$BUILD_DIR" && lb clean --purge >/dev/null 2>&1 || true )
    rm -rf "$BUILD_DIR"
  fi
  ok "Clean complete"
}

# --------------------------------------------------------------------------- #
# Configure the live-build tree.
# --------------------------------------------------------------------------- #
configure() {
  say "Configuring live-build tree at ${BUILD_DIR}"
  mkdir -p "$BUILD_DIR"
  cd "$BUILD_DIR"

  lb config \
    --mode debian \
    --distribution "$DIST" \
    --architectures "$ARCH" \
    --archive-areas "main contrib non-free non-free-firmware" \
    --binary-images "$BINARY_IMAGES" \
    --debian-installer none \
    --bootloaders "$BOOTLOADERS" \
    --bootappend-live "$BOOTAPPEND" \
    --firmware-chroot true \
    --firmware-binary true \
    --memtest none \
    --apt-indices false \
    --apt-recommends true \
    --security true \
    --updates true \
    --backports false \
    --mirror-bootstrap "$MIRROR" \
    --mirror-binary "$MIRROR" \
    --iso-application "ThinClient OS" \
    --iso-publisher "ThinClient Project" \
    --iso-preparer "build.sh (live-build)" \
    --iso-volume "THINCLIENT ${VERSION}"

  ok "live-build configured"
}

# --------------------------------------------------------------------------- #
# Copy package lists, hooks, and staged files into the tree.
# --------------------------------------------------------------------------- #
# Resolve "#if ARCHITECTURES ..." / "#endif" blocks in a package list against
# the target arch ourselves, so correctness never depends on live-build's
# preprocessor being enabled. Emits a plain list of the matching packages.
filter_pkglist() {
  local src="$1" dst="$2"
  awk -v arch="$ARCH" '
    /^[[:space:]]*#if[[:space:]]+ARCHITECTURES/ {
      m=0; for (i=3;i<=NF;i++) if ($i==arch) m=1; in_if=1; keep=m; next
    }
    /^[[:space:]]*#endif/ { in_if=0; keep=1; next }
    { if (in_if && !keep) next; print }
  ' "$src" >"$dst"
}

populate() {
  say "Installing package lists and hooks (arch=${ARCH})"
  install -d "${BUILD_DIR}/config/package-lists"
  local pl
  for pl in "${PROJECT_ROOT}"/config/live-build/package-lists/*.list.chroot; do
    filter_pkglist "$pl" "${BUILD_DIR}/config/package-lists/$(basename "$pl")"
  done

  install -d "${BUILD_DIR}/config/hooks/live"
  cp "${PROJECT_ROOT}"/config/live-build/hooks/*.hook.chroot \
     "${BUILD_DIR}/config/hooks/live/"
  chmod +x "${BUILD_DIR}/config/hooks/live/"*.hook.chroot

  say "Staging appliance files into the root filesystem"

  # --- Executables -> /opt/thinclient/bin --------------------------------
  local bins="thinclient-splash thinclient-session thinclient-watchdog \
              thinclient-xsession thinclient-config thinclient-adminctl \
              thinclient-test-connection thinclient-admin thinclient-adminmode \
              thinclient-netctl thinclient-diagnostics thinclient-firstboot \
              thinclient-wifi thinclient-netwait"
  local b
  for b in $bins; do
    stage "scripts/${b}" "/opt/thinclient/bin/${b}" 0755
  done

  # --- Libraries -> /opt/thinclient/lib ----------------------------------
  stage "scripts/lib/thinclient-common.sh" "/opt/thinclient/lib/thinclient-common.sh" 0644
  stage "scripts/lib/rdp-build-args.sh"    "/opt/thinclient/lib/rdp-build-args.sh"    0644

  # --- Disk installer (available inside the live session) ----------------
  stage "installer/install-to-disk.sh" "/opt/thinclient/bin/thinclient-install" 0755

  # --- Config ------------------------------------------------------------
  stage "config/server.conf"          "/etc/thinclient/server.conf"                    0644
  stage "config/admin.conf"           "/etc/thinclient/admin.conf"                     0600
  stage "config/openbox/rc.xml.in"    "/opt/thinclient/share/openbox/rc.xml.in"        0644
  stage "config/xorg/10-thinclient-kiosk.conf" "/etc/X11/xorg.conf.d/10-thinclient-kiosk.conf" 0644
  stage "config/xorg/Xwrapper.config" "/etc/X11/Xwrapper.config"                       0644
  stage "config/sudoers-thinclient"   "/etc/sudoers.d/thinclient"                      0440
  stage "config/logrotate-thinclient" "/etc/logrotate.d/thinclient"                    0644

  # --- systemd units -----------------------------------------------------
  local u
  for u in "${PROJECT_ROOT}"/systemd/*.service; do
    stage "systemd/$(basename "$u")" "/etc/systemd/system/$(basename "$u")" 0644
  done

  # --- Plymouth theme ----------------------------------------------------
  stage "assets/plymouth/thinclient/thinclient.plymouth" "/usr/share/plymouth/themes/thinclient/thinclient.plymouth" 0644
  stage "assets/plymouth/thinclient/thinclient.script"   "/usr/share/plymouth/themes/thinclient/thinclient.script"   0644

  # --- Branding + docs (available on the appliance) ----------------------
  stage "assets/branding/connecting.svg" "/opt/thinclient/assets/connecting.svg" 0644
  local d
  for d in "${PROJECT_ROOT}"/docs/*.md; do
    [[ -e "$d" ]] || continue
    stage "docs/$(basename "$d")" "/opt/thinclient/docs/$(basename "$d")" 0644
  done

  # --- Record the build version/date into the marker ---------------------
  install -d "${BUILD_DIR}/config/includes.chroot/etc/thinclient"
  {
    echo "product=ThinClient OS"
    echo "version=${VERSION}"
    echo "build_date=$(date --iso-8601=seconds)"
    echo "base=Debian ${DIST}"
  } >"${BUILD_DIR}/config/includes.chroot/etc/thinclient/build-info"

  ok "Root filesystem staged"
}

# --------------------------------------------------------------------------- #
# Build and collect the ISO.
# --------------------------------------------------------------------------- #
build() {
  say "Building the image (this can take 15-40 minutes on the first run)"
  cd "$BUILD_DIR"
  lb build 2>&1 | tee "${PROJECT_ROOT}/build/build.log"

  local produced
  produced="$(ls -1 "${BUILD_DIR}"/live-image-*.hybrid.iso 2>/dev/null | head -n1 || true)"
  [[ -n "$produced" ]] || die "Build finished but no ISO was produced. See build/build.log."

  install -d "${PROJECT_ROOT}/iso"
  cp -f "$produced" "$OUTPUT_ISO"
  ( cd "${PROJECT_ROOT}/iso" && sha256sum "$(basename "$OUTPUT_ISO")" >"$(basename "$OUTPUT_ISO").sha256" )

  ok "ISO ready: ${OUTPUT_ISO}"
  printf '    size: %s\n' "$(du -h "$OUTPUT_ISO" | cut -f1)"
  printf '    sha256: %s\n' "$(cut -d' ' -f1 "${OUTPUT_ISO}.sha256")"
  cat <<EOF

${c_green}Next steps:${c_off}
  1. Write to USB:   sudo dd if=${OUTPUT_ISO} of=/dev/sdX bs=4M status=progress oflag=sync
  2. Boot the target machine from USB.
  3. Edit the server:  Admin hotkey (Ctrl+Alt+Shift+A) -> Configure
  4. Install to disk:  Admin Mode is live-only; to persist run
                       'sudo thinclient-install' from the live session,
                       then clone the fleet with Clonezilla (see docs/CLONEZILLA.md).
EOF
}

# --------------------------------------------------------------------------- #
# Main.
# --------------------------------------------------------------------------- #
main() {
  local do_clean_first=0 do_build=1
  case "${1:-}" in
    --clean)   do_clean_first=1; do_build=0 ;;
    --rebuild) do_clean_first=1; do_build=1 ;;
    --help|-h) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    "")        : ;;
    *)         die "Unknown option: $1 (see --help)" ;;
  esac

  preflight

  # Fresh clone? The real config is gitignored; seed it from the template so the
  # build never fails on a missing server.conf. Edit it before deploying.
  if [[ ! -f "${PROJECT_ROOT}/config/server.conf" && -f "${PROJECT_ROOT}/config/server.conf.example" ]]; then
    cp "${PROJECT_ROOT}/config/server.conf.example" "${PROJECT_ROOT}/config/server.conf"
    warn "No config/server.conf found — created one from server.conf.example. Edit it before deploying."
  fi

  (( do_clean_first )) && do_clean
  (( do_build )) || { ok "Clean-only run complete"; exit 0; }

  mkdir -p "${PROJECT_ROOT}/build" "${PROJECT_ROOT}/iso"
  configure
  populate
  build
}

main "$@"
