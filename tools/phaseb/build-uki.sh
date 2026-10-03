#!/bin/bash
# Inside the Dockerfile.uki container:  build-uki.sh <out-dir>   (keys mounted at /keys)
# Installs the CURRENT Debian kernel, builds a generic (no-hostonly) dracut initrd with
# systemd + TPM2 + LUKS, wraps both in a UKI with a fixed, signed command line, signs it
# for Secure Boot and embeds a signed policy for TPM PCR 11.
set -euo pipefail
OUT="$1"; mkdir -p "$OUT"
# Every encrypted install uses this LUKS UUID, so the SIGNED command line can name the
# root device. The TPM, not the UUID, is what ties a disk to its machine.
LUKS_UUID="${TC_LUKS_UUID:-7c1d0e6a-5b21-4f0e-9a6b-7468696e636c}"
apt-get update -qq
apt-get install -y -qq --no-install-recommends linux-image-amd64 >/dev/null
KVER=$(ls /lib/modules | sort -V | tail -1)
echo "kernel: $KVER"
CMDLINE="rd.luks.name=${LUKS_UUID}=root rd.luks.options=${LUKS_UUID}=tpm2-device=auto,headless=true root=/dev/mapper/root rw quiet splash lockdown=confidentiality loglevel=3"
dracut --force --no-hostonly --kver "$KVER" \
  --add "systemd crypt systemd-cryptsetup tpm2-tss" \
  --omit "plymouth network network-manager iscsi nfs" \
  "$OUT/initrd-$KVER.img" 2>&1 | tail -2
ukify build \
  --linux "/boot/vmlinuz-$KVER" --initrd "$OUT/initrd-$KVER.img" \
  --cmdline "$CMDLINE" --os-release @/etc/os-release --uname "$KVER" \
  --secureboot-private-key /keys/secureboot/MOK.key --secureboot-certificate /keys/secureboot/MOK.crt \
  --pcr-private-key /keys/pcr/tpm2-pcr-private.pem --pcr-public-key /keys/pcr/tpm2-pcr-public.pem \
  --output "$OUT/thinclient-$KVER.efi"
sbverify --cert /keys/secureboot/MOK.crt "$OUT/thinclient-$KVER.efi"
echo "$KVER" > "$OUT/KVER"; echo "$LUKS_UUID" > "$OUT/LUKS_UUID"
ls -la "$OUT"
