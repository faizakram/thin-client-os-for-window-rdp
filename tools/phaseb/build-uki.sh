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
# Every boot unlocks through the TPM. The installer seals the key into the machine's TPM
# with NO PCR conditions (it runs under a different boot chain, so PCR 7 would not match);
# first boot (tc-tpm-enroll) re-seals it to PCR 7 + our signed PCR 11 policy and wipes
# the unconditional seal. No key file is ever written to disk. (A key file plus
# tpm2-device=auto crashed systemd-cryptsetup 257 while no TPM token existed yet, and a
# key file alone never falls back to the token once the file is gone.)
# The rest mirrors what the GRUB installer sets on unencrypted machines (there is no GRUB
# here): a silent kiosk boot, and usbcore.autosuspend=-1 — the camera fix (a suspended
# NO boot splash (plymouth.enable=0): GRUB machines start Plymouth inside the initramfs
# together with the GPU driver; this initrd has neither, so Plymouth started LATE on the
# firmware framebuffer and collided with amdgpu taking over — on a real AMD machine X
# then never became ready and the screen stayed black (the VM, no amdgpu, was fine).
#
# webcam that fails to resume drops off the bus mid-recording).
#
# panic=10 rd.shell=0 rd.emergency=reboot: a kernel that cannot start restarts instead of
# hanging, so systemd-boot's try counter runs down and the previous image starts again
# (kernel updates, see tc-boot-bless). An unlock the TPM refuses (disk moved, Secure Boot
# off) therefore restarts in a loop instead of hanging - the disk stays locked either way.
CMDLINE="rd.luks.name=${LUKS_UUID}=root rd.luks.options=${LUKS_UUID}=tpm2-device=auto,headless=true root=/dev/mapper/root rw lockdown=confidentiality quiet plymouth.enable=0 loglevel=0 vt.global_cursor_default=0 rd.systemd.show_status=false systemd.show_status=false usbcore.autosuspend=-1 panic=10 rd.shell=0 rd.emergency=reboot"
# Debug build only (TC_UKI_DEBUG=1): everything to the serial console as well.
[ "${TC_UKI_DEBUG:-0}" = 1 ] && CMDLINE="$CMDLINE console=tty0 console=ttyS0,115200 systemd.log_level=debug systemd.log_target=console rd.udev.log_level=info"
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
# Memory hardening for encrypted machines: their command line is sealed in the image, so
# the parameters ship as a signed systemd-boot add-on the agent places or removes on the
# boot partition (\loader\addons). Same parameters as the GRUB machines get.
ukify build --cmdline "init_on_alloc=1 init_on_free=1 intel_iommu=on,igfx_off" \
  --secureboot-private-key /keys/secureboot/MOK.key --secureboot-certificate /keys/secureboot/MOK.crt \
  --output "$OUT/tc-mem-harden.addon.efi"
sbverify --cert /keys/secureboot/MOK.crt "$OUT/tc-mem-harden.addon.efi"
# The boot manager between shim and the image: Debian-signed (shim trusts Debian's CA).
cp /usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed "$OUT/systemd-bootx64.efi.signed"
# The kernel package whose modules this image loads: delivered with the image when it
# ships as a kernel update (thinclient-kernel installs it before the image).
apt-get download -qq "linux-image-$KVER" >/dev/null 2>&1 && mv linux-image-"$KVER"_*.deb "$OUT/" || true
ls -la "$OUT"
