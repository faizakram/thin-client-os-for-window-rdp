#!/bin/bash
# Phase B: run the REAL installer (thinclient-install) from an encrypted ISO against a
# virtual disk, sealing into the test VM's software TPM, so the result can then be booted
# in the Secure Boot + TPM rig. Run in a PRIVILEGED amd64 container:
#   docker run --rm --privileged --platform linux/amd64 -v <iso>:/iso:ro \
#     -v tc-rig-work:/work -v <repo>:/project:ro tc-uki-builder \
#     bash /project/tests/vm/installer-test.sh <vm-name>
# The ISO's enrolment token is BLANKED in this throwaway copy so the test never sends
# an install request to a real manager.
set -euo pipefail
VM="$1"; W="/work/$VM"
(apt-get update -qq && apt-get install -y -qq squashfs-tools libarchive-tools swtpm swtpm-tools qemu-utils gdisk) >/dev/null 2>&1
rm -rf "$W"; mkdir -p "$W/tpm"

echo "== unpack the ISO's system"
cd /tmp && bsdtar -xf /iso live/filesystem.squashfs
rm -rf /live && unsquashfs -q -d /live live/filesystem.squashfs >/dev/null
sed -i 's/^TENANT_TOKEN=.*/TENANT_TOKEN=/' /live/etc/thinclient/license.conf
# /opt/thinclient is an ABSOLUTE symlink: check it as the installer will see it.
chroot /live test -f /opt/thinclient/phaseb/thinclient.efi || { echo "NOT an encrypted image"; exit 1; }
# TC_USE_REPO_INSTALLER=1: test the installer from the repo instead of the image's copy
# (iterate on fixes without a 20-minute ISO rebuild; the final ISO is rebuilt anyway).
if [ "${TC_USE_REPO_INSTALLER:-0}" = 1 ]; then
  install -m 0755 /project/installer/install-to-disk.sh "$(chroot /live readlink -f /opt/thinclient/bin)/thinclient-install" 2>/dev/null \
    || install -m 0755 /project/installer/install-to-disk.sh "/live$(chroot /live readlink -f /opt/thinclient/bin/thinclient-install)"
  BIN="/live$(chroot /live readlink -f /opt/thinclient/bin)"
  install -m 0755 /project/scripts/thinclient-enroll "$BIN/thinclient-enroll"
  install -m 0755 /project/tools/phaseb/tc-tpm-enroll "/live$(chroot /live readlink -f /opt/thinclient/phaseb)/tc-tpm-enroll"
  echo "   (using the repo's installer, enroll and first-boot seal)"
fi

echo "== virtual disk + a tiny udev (containers create no partition nodes)"
truncate -s 16G /tmp/disk.raw
LOOP=$(losetup --find --show --partscan /tmp/disk.raw)
( while :; do for p in /sys/block/$(basename "$LOOP")/$(basename "$LOOP")p*; do
    [ -e "$p/dev" ] || continue; n=/dev/$(basename "$p")
    want="$(cut -d: -f1 "$p/dev"):$(cut -d: -f2 "$p/dev")"
    # Repartitioning renumbers the partitions: replace a node whose number went stale.
    if [ ! -b "$n" ] || [ "$(printf '%d:%d' 0x$(stat -c %t "$n") 0x$(stat -c %T "$n"))" != "$want" ]; then
      rm -f "$n"; mknod "$n" b "${want%%:*}" "${want##*:}"; fi; done; sleep 0.1; done ) &
NODES=$!

echo "== the test VM's TPM, reachable inside the installer's root"
mkdir -p /live/run/tpm
swtpm socket --tpm2 --tpmstate dir="$W/tpm" --server type=unixio,path=/live/run/tpm/sock \
  --ctrl type=unixio,path=/live/run/tpm/sock.ctrl --flags startup-clear --seccomp action=none \
  --pid file=/tmp/swtpm.pid --daemon
for fs in dev proc sys; do mount --rbind /$fs /live/$fs; done
cp /etc/resolv.conf /live/etc/resolv.conf
# The software-TPM connector is a TEST dependency only (real machines use /dev/tpmrm0).
chroot /live bash -c 'ls /usr/lib/x86_64-linux-gnu/libtss2-tcti-swtpm.so.0* >/dev/null 2>&1 || (apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq libtss2-tcti-swtpm0t64) >/dev/null 2>&1'

echo "== run the installer (answers: confirm disk, device name)"
set +e
if [ "${TC_UI_MODE:-0}" = 1 ]; then
  # Exactly what the install wizard runs: answers as options, "@@TC" lines back, no prompts.
  chroot /live env TC_INSTALL_TEST=1 TC_TPM2_DEVICE=swtpm:path=/run/tpm/sock \
    /opt/thinclient/bin/thinclient-install --ui --disk "$LOOP" --confirm "$LOOP" --name PhaseB-Test-01 </dev/null >/tmp/ui.out 2>&1
  RC=$?
  echo "-- @@TC lines:"; tr '\r' '\n' </tmp/ui.out | grep '^@@TC' ; echo "-- tail:"; tr '\r' '\n' </tmp/ui.out | grep -vE "^\s+[0-9,]+\s+[0-9]+%|to-chk|^@@TC" | tail -15
else
printf '%s\nPhaseB-Test-01\n' "$LOOP" | chroot /live env TC_INSTALL_TEST=1 TC_TPM2_DEVICE=swtpm:path=/run/tpm/sock \
  /opt/thinclient/bin/thinclient-install "$LOOP" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -vE "^\s+[0-9,]+\s+[0-9]+%|to-chk" | tail -40
RC=${PIPESTATUS[1]}
fi
set -e
echo "== installer exit: $RC"

kill "$(cat /tmp/swtpm.pid)" 2>/dev/null || true; kill $NODES 2>/dev/null || true
for fs in sys proc dev; do umount -R -l /live/$fs 2>/dev/null || true; done
cryptsetup close tc-install-root 2>/dev/null || true
echo "== disk after install:"; sgdisk -p "$LOOP" | tail -3
cryptsetup luksDump "${LOOP}p2" | sed -n '/^Tokens:/,/^Digests:/p' | grep -E "systemd-tpm2|Keyslot|pcrs" || true
cryptsetup luksDump "${LOOP}p2" | sed -n '/^Keyslots:/,/^Tokens:/p' | grep -E "^  [0-9]+: " || true
losetup -d "$LOOP"
[ "$RC" = 0 ] || exit "$RC"
qemu-img convert -O qcow2 /tmp/disk.raw "$W/disk.qcow2" && rm /tmp/disk.raw
cp /work/encA/vars-1.fd "$W/vars-1.fd"      # firmware that already trusts our key (enrolment proven in M3)
echo "== ready to boot: $W"
