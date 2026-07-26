#!/usr/bin/env bash
# =============================================================================
#  ThinClient OS — one-shot builder bootstrap for an amd64 Linux host
#
#  Run this on ANY amd64 (x86_64) Debian 12/13 or Ubuntu 22.04+ machine to
#  install the live-build toolchain and produce the deployable amd64 ISO.
#
#  This is the reliable path to the fleet image. Building an amd64 rootfs under
#  Apple-Silicon emulation fails in debootstrap ("tar failed"), so build here
#  (a cheap cloud VM, a spare PC, WSL2 on x86 Windows, or CI) instead.
#
#  Usage:
#     ./bootstrap-build-host.sh            # install deps + build
#     ./bootstrap-build-host.sh --rebuild  # clean + build
# =============================================================================
set -euo pipefail

# Re-exec with sudo if not root (preserving the repo directory).
if [[ "$(id -u)" -ne 0 ]]; then
  echo "Elevating with sudo..."
  exec sudo -E bash "$0" "$@"
fi

ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"
if [[ "$ARCH" != "amd64" && "$ARCH" != "x86_64" ]]; then
  echo "ERROR: this host is '${ARCH}', but the fleet image targets amd64." >&2
  echo "       Run this on an x86_64 Linux host. (See docs/BUILDING.md.)" >&2
  exit 1
fi

echo "==> Installing live-build toolchain"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  live-build debootstrap xorriso squashfs-tools \
  grub-pc-bin grub-efi-amd64-bin isolinux syslinux-common \
  mtools dosfstools ca-certificates rsync file

echo "==> Building the ISO"
cd "$(dirname "$(readlink -f "$0")")"
./build.sh "$@"

echo
echo "Done. Deployable image: iso/thinclient.iso"
