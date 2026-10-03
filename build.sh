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
rd.systemd.show_status=false systemd.show_status=false udev.log_level=0 \
usbcore.autosuspend=-1 noeject"
# noeject: live-tools otherwise stops every shutdown at "remove the live medium and
# press ENTER" - on a black screen, so a restart looked frozen until a hard power-off.
# NOTE: hardware KMS (native graphics) is the default so the display runs at the
# panel's true resolution. The AMD box that black-screened before now has its
# GPU firmware (firmware-amd-graphics) in the image, so amdgpu KMS initialises
# correctly. live-build's built-in "fail-safe" GRUB entry remains as a fallback,
# and iso/thinclient-safe-nomodeset.iso is kept as a safe-graphics backup.

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
  [[ -d "$BUILD_DIR" ]] || { ok "Nothing to clean"; return 0; }
  local keep; keep="$(dirname "$BUILD_DIR")/.tc-cache-keep"
  if [[ "${TC_KEEP_CACHE:-1}" == "1" && -d "$BUILD_DIR/cache" ]]; then
    # Preserve live-build's download cache (bootstrap base + .debs) across
    # rebuilds so we don't re-download the whole base system every time.
    say "Cleaning build (keeping download cache for fast rebuilds)"
    rm -rf "$keep"
    mv "$BUILD_DIR/cache" "$keep"
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"
    mv "$keep" "$BUILD_DIR/cache"
  else
    say "Cleaning previous build artifacts (full purge)"
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
    --iso-application "Thin Client" \
    --iso-publisher "Thin Client" \
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
    # The SSH server is a DEBUG-only package. A production image used to ship it
    # (disabled), which left a remote-login service one systemctl away; now it is not
    # installed at all unless the image is explicitly built with TC_DEBUG_SSH=1.
    if [[ "$(basename "$pl")" == *debug-ssh* && "${TC_DEBUG_SSH:-0}" != "1" ]]; then
      continue
    fi
    filter_pkglist "$pl" "${BUILD_DIR}/config/package-lists/$(basename "$pl")"
  done

  install -d "${BUILD_DIR}/config/hooks/live"
  cp "${PROJECT_ROOT}"/config/live-build/hooks/*.hook.chroot \
     "${BUILD_DIR}/config/hooks/live/" 2>/dev/null || true
  # Binary-stage hooks (e.g. boot-menu rebranding) run when the ISO tree is
  # assembled; copy them too if present.
  cp "${PROJECT_ROOT}"/config/live-build/hooks/*.hook.binary \
     "${BUILD_DIR}/config/hooks/live/" 2>/dev/null || true
  chmod +x "${BUILD_DIR}/config/hooks/live/"*.hook.* 2>/dev/null || true

  say "Staging appliance files into the root filesystem"

  # --- Executables -> /opt/thinclient/bin --------------------------------
  # EVERY scripts/thinclient-*, exactly as make-update-bundle.sh ships them. This was a
  # hand-kept list, and a new script added to the OTA but not here (secpolicy, ospatch)
  # made a fresh install silently lack it — while already claiming the version that
  # has it, so no update would ever bring it. tests/check-iso-scripts.sh guards this.
  local f
  for f in "${PROJECT_ROOT}"/scripts/thinclient-*; do
    [[ -f "$f" ]] || continue
    stage "scripts/$(basename "$f")" "/opt/thinclient/bin/$(basename "$f")" 0755
  done

  # --- Libraries -> /opt/thinclient/lib ----------------------------------
  stage "scripts/lib/thinclient-common.sh" "/opt/thinclient/lib/thinclient-common.sh" 0644
  stage "scripts/lib/rdp-build-args.sh"    "/opt/thinclient/lib/rdp-build-args.sh"    0644

  # --- Disk installer (available inside the live session) ----------------
  stage "installer/install-to-disk.sh" "/opt/thinclient/bin/thinclient-install" 0755

  # --- Encrypted installs (security plan Phase B) -------------------------------
  # TC_ENCRYPTED=1: carry the SIGNED boot image (built by tools/phaseb/build-uki.sh
  # into build-phaseb/) plus the PUBLIC certificate and PCR-policy key. Their presence
  # is what makes the installer install encrypted. Private keys never enter the image.
  if [[ "${TC_ENCRYPTED:-0}" == "1" ]]; then
    local PB="${PROJECT_ROOT}/build-phaseb" kver
    kver="$(cat "$PB/KVER" 2>/dev/null)" || die "TC_ENCRYPTED=1 but no build-phaseb/KVER — run tools/phaseb/build-uki.sh first"
    [[ -s "$PB/thinclient-${kver}.efi" ]] || die "missing signed boot image build-phaseb/thinclient-${kver}.efi"
    stage "build-phaseb/thinclient-${kver}.efi"   "/opt/thinclient/phaseb/thinclient.efi" 0644
    stage "build-phaseb/KVER"                    "/opt/thinclient/phaseb/KVER" 0644
    stage "build-phaseb/LUKS_UUID"               "/opt/thinclient/phaseb/LUKS_UUID" 0644
    stage "keys/secureboot/MOK.der"              "/opt/thinclient/phaseb/MOK.der" 0644
    stage "keys/pcr/tpm2-pcr-public.pem"         "/opt/thinclient/phaseb/tpm2-pcr-public-key.pem" 0644
    stage "tools/phaseb/tc-tpm-enroll"           "/opt/thinclient/phaseb/tc-tpm-enroll" 0755
    ok "Encrypted image: signed boot image for kernel ${kver} staged"
  fi

  # --- Config ------------------------------------------------------------
  stage "config/server.conf"          "/etc/thinclient/server.conf"                    0644
  stage "config/admin.conf"           "/etc/thinclient/admin.conf"                     0600
  stage "config/openbox/rc.xml.in"    "/opt/thinclient/share/openbox/rc.xml.in"        0644
  stage "config/xorg/10-thinclient-kiosk.conf" "/etc/X11/xorg.conf.d/10-thinclient-kiosk.conf" 0644
  stage "config/xorg/Xwrapper.config" "/etc/X11/Xwrapper.config"                       0644
  stage "config/sudoers-thinclient"   "/etc/sudoers.d/thinclient"                      0440
  stage "config/logrotate-thinclient" "/etc/logrotate.d/thinclient"                    0644

  # --- OTA update public key (verifies signed manifests) -----------------
  # Private half (update-signing-key.pem) NEVER ships — it stays on the build host.
  stage "config/update-pubkey.pem"    "/etc/thinclient/update-pubkey.pem"              0644

  # --- Device licensing / management agent config + trust anchor -------------
  stage "config/license.conf"         "/etc/thinclient/license.conf"                   0644
  if [[ -f "${PROJECT_ROOT}/config/license-pubkey.pem" ]]; then
    stage "config/license-pubkey.pem" "/etc/thinclient/license-pubkey.pem"             0644
  fi

  # --- Bake fleet auto-enrolment into the shipped license.conf (optional) ------
  # When TC_TENANT_TOKEN (and/or TC_CONTROL_URL / TC_LICENSE_ENFORCE) is set at
  # build time, write it into the staged license.conf so EVERY machine installed
  # from this ISO self-registers into that tenant on first boot — no activation
  # USB, no manual step. Injected here at build time; NEVER committed to git.
  local LCONF="${BUILD_DIR}/config/includes.chroot/etc/thinclient/license.conf"
  local kv k v
  # The manager URL is not in the (public) source. It comes from the environment, or
  # from the untracked config/build.local.env (KEY=value lines), which is where the
  # usual values live on the build machine.
  if [[ -z "${TC_CONTROL_URL:-}" && -f "${PROJECT_ROOT}/config/build.local.env" ]]; then
    TC_CONTROL_URL="$(sed -n 's/^TC_CONTROL_URL=//p' "${PROJECT_ROOT}/config/build.local.env" | tail -1)"
  fi
  for kv in "CONTROL_URL=${TC_CONTROL_URL:-}" "TENANT_TOKEN=${TC_TENANT_TOKEN:-}" "LICENSE_ENFORCE=${TC_LICENSE_ENFORCE:-}"; do
    k="${kv%%=*}"; v="${kv#*=}"
    [[ -n "$v" ]] || continue
    if grep -q "^${k}=" "$LCONF"; then sed -i "s#^${k}=.*#${k}=${v}#" "$LCONF"; else printf '%s=%s\n' "$k" "$v" >>"$LCONF"; fi
  done
  if [[ -n "${TC_TENANT_TOKEN:-}" ]]; then
    ok "Baked fleet auto-enrol token into license.conf — installs self-register"
  fi
  # An image with no manager URL installs devices that can never enrol, update or be
  # managed — and nothing about it looks wrong until it is on a desk. Refuse to build.
  if ! grep -q '^CONTROL_URL=..*' "$LCONF"; then
    die "No manager URL: set TC_CONTROL_URL, or put TC_CONTROL_URL=https://... in config/build.local.env"
  fi

  # udev rule: activate the device from a USB stick on insert (no shell needed)
  stage "config/udev/99-thinclient-provision.rules" "/etc/udev/rules.d/99-thinclient-provision.rules" 0644
  # USB Wi-Fi stability: stop rtl88xxau dongles power-cycling (drops Wi-Fi + RDP).
  # (The agent also writes these at runtime so OTA devices get the fix without a
  # reflash; baking them makes the modprobe params apply from the first module load.)
  stage "config/udev/72-thinclient-wifi-nopm.rules" "/etc/udev/rules.d/72-thinclient-wifi-nopm.rules" 0644
  stage "config/modprobe.d/thinclient-wifi.conf"    "/etc/modprobe.d/thinclient-wifi.conf"            0644
  stage "config/NetworkManager/conf.d/wifi-powersave.conf" "/etc/NetworkManager/conf.d/wifi-powersave.conf" 0644
  # USB webcam stability: never autosuspend a camera. A webcam that is suspended and
  # fails to resume drops off the bus (-71/EPROTO) and the recording silently loses
  # its camera track until somebody physically replugs it. The agent also applies
  # this at runtime, so the existing fleet gets it over the air; baking it means a
  # fresh install is correct from the very first boot.
  stage "config/udev/73-thinclient-camera-nopm.rules" "/etc/udev/rules.d/73-thinclient-camera-nopm.rules" 0644

  # --- systemd units (.service + .timer) ---------------------------------
  local u
  for u in "${PROJECT_ROOT}"/systemd/*.service "${PROJECT_ROOT}"/systemd/*.timer; do
    [[ -e "$u" ]] || continue
    stage "systemd/$(basename "$u")" "/etc/systemd/system/$(basename "$u")" 0644
  done

  # --- tmpfiles.d: shared /run/thinclient signal dir (activity + recording) ---
  stage "config/tmpfiles.d/thinclient.conf" "/usr/lib/tmpfiles.d/thinclient.conf" 0644

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

  # VERSION stamp the OTA updater compares against. The chroot hook converts
  # /opt/thinclient into the /opt/thinclient-releases/<version> symlink layout
  # so future updates swap atomically.
  install -d "${BUILD_DIR}/config/includes.chroot/opt/thinclient"
  printf '%s\n' "${VERSION}" >"${BUILD_DIR}/config/includes.chroot/opt/thinclient/VERSION"

  # Build flags the chroot hook reads. DEBUG_SSH defaults OFF (production): no
  # openssh debug user / root password. Rebuild with TC_DEBUG_SSH=1 for a
  # debug image.
  {
    echo "DEBUG_SSH=${TC_DEBUG_SSH:-0}"
  } >"${BUILD_DIR}/config/includes.chroot/etc/thinclient/.build-flags"

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

  # An encrypted image boots INSTALLED machines through the signed boot image, whose
  # kernel must be the one whose modules are in the image. A mismatch installs machines
  # that boot a kernel with no matching modules — refuse rather than ship that.
  if [[ "${TC_ENCRYPTED:-0}" == "1" ]]; then
    local want have
    want="$(cat "${PROJECT_ROOT}/build-phaseb/KVER")"
    have="$(ls "${BUILD_DIR}/chroot/lib/modules" 2>/dev/null | sort -V | tail -1)"
    [[ "$want" == "$have" ]] || die "Kernel mismatch: signed boot image is ${want}, image has ${have}. Rebuild the boot image (tools/phaseb/build-uki.sh) and the ISO on the same day."
    ok "Kernel check: signed boot image and image both ${want}"
  fi

  install -d "${PROJECT_ROOT}/iso"
  # Unlink first, then copy. `cp -f` opens the existing file and truncates it, so it
  # writes THROUGH to the same inode — and every previously named tenant ISO is a hard
  # link to that inode. Copying in place therefore silently rewrote every past image:
  # thinclient-1.0.122-quantum.iso ended up containing a completely different build
  # while still carrying 1.0.122 in its name. A bootable image whose filename lies
  # about its contents is the exact failure the per-tenant naming exists to prevent.
  # Removing the link first gives each build a fresh inode and leaves history intact.
  rm -f "$OUTPUT_ISO"
  cp -f "$produced" "$OUTPUT_ISO"
  ( cd "${PROJECT_ROOT}/iso" && sha256sum "$(basename "$OUTPUT_ISO")" >"$(basename "$OUTPUT_ISO").sha256" )

  # A tenant-specific image MUST be identifiable from its filename. An ISO carries a
  # baked enrolment token, so flashing the wrong tenant's image silently enrols the
  # machine into the wrong fleet — a mistake that is invisible until it has happened.
  # Hard link, not a copy: same inode, so the second name costs no extra disk.
  local tenant_slug=""
  if [[ -n "${TC_TENANT_NAME:-}" ]]; then
    tenant_slug="$(printf '%s' "$TC_TENANT_NAME" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-*//; s/-*$//')"
  elif [[ -n "${TC_TENANT_TOKEN:-}" ]]; then
    tenant_slug="tenant"   # token baked but nobody told us whose — still flag it
  fi
  local NAMED_ISO=""
  if [[ -n "$tenant_slug" ]]; then
    NAMED_ISO="${PROJECT_ROOT}/iso/thinclient-${VERSION}-${tenant_slug}$([[ "${TC_ENCRYPTED:-0}" == "1" ]] && echo -encrypted).iso"
    ln -f "$OUTPUT_ISO" "$NAMED_ISO" 2>/dev/null || cp -f "$OUTPUT_ISO" "$NAMED_ISO"
    ( cd "${PROJECT_ROOT}/iso" && sha256sum "$(basename "$NAMED_ISO")" >"$(basename "$NAMED_ISO").sha256" )
  fi

  ok "ISO ready: ${OUTPUT_ISO}"
  if [[ -n "$NAMED_ISO" ]]; then
    ok "Tenant image: ${NAMED_ISO}"
    if [[ "$tenant_slug" == "tenant" ]]; then
      warn "Set TC_TENANT_NAME=<tenant> so the filename names the tenant, not just 'tenant'"
    fi
  fi
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
