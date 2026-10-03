#!/bin/bash
# Phase B M3 prototype — what the encrypted installer will do, on a disk image, so the
# whole chain (Secure Boot -> MOK -> signed UKI -> TPM unlock) can be proven in the VM
# before the real installer is written. Run in a PRIVILEGED amd64 container with:
#   /iso   the Plan A ISO (its root filesystem becomes the installed system)
#   /uki   build-phaseb (thinclient-<kver>.efi, KVER, LUKS_UUID)
#   /keys  keys/ (only the PUBLIC parts are copied onto the disk)
#   /tools this directory
#   /tpm   the TARGET machine's TPM: a swtpm state dir (the VM's), served on a socket here.
#          The real installer uses the machine's own /dev/tpmrm0 instead.
#   make-encrypted-disk.sh <out.raw> [size]
set -euo pipefail
OUT="$1"; SIZE="${2:-16G}"
KVER=$(cat /uki/KVER); LUKS_UUID=$(cat /uki/LUKS_UUID); UKI=/uki/thinclient-$KVER.efi
apt-get update -qq
apt-get install -y -qq --no-install-recommends gdisk dosfstools squashfs-tools libarchive-tools \
  shim-signed rsync cryptsetup e2fsprogs swtpm swtpm-tools libtss2-tcti-swtpm0t64 systemd-cryptsetup >/dev/null

rm -f "$OUT"; truncate -s "$SIZE" "$OUT"
# GPT: ESP + root. Root carries the "Linux root (x86-64)" type GUID.
sgdisk --zap-all -n1:0:+1G -t1:ef00 -c1:TCEFI -n2:0:0 -t2:8304 -c2:THINCLIENT_ROOT "$OUT" >/dev/null
# One loop device per partition at its byte offset (containers have no udev, so
# --partscan device nodes never appear).
part_loop(){ local n=$1 start size
  read -r start size < <(partx -g -o START,SECTORS -n "$n" "$OUT")
  losetup --find --show --offset $((start*512)) --sizelimit $((size*512)) "$OUT"; }
ESP=$(part_loop 1); ROOT=$(part_loop 2)
cleanup(){ set +e; umount -R /mnt/t 2>/dev/null; cryptsetup close tcroot 2>/dev/null; losetup -d "$ESP" "$ROOT"; }
trap cleanup EXIT
mkfs.vfat -F32 -n TCEFI "$ESP" >/dev/null

# LUKS2, AES-256-XTS, fixed UUID (the signed command line names it). A random passphrase
# exists only for the minutes of this install: the key is sealed into the TARGET TPM
# (no PCR conditions yet) and the passphrase slot wiped before we finish.
KEY=$(mktemp); head -c 64 /dev/urandom > "$KEY"
swtpm socket --tpm2 --tpmstate dir=/tpm --server type=unixio,path=/tmp/tpm.sock \
  --ctrl type=unixio,path=/tmp/tpm.sock.ctrl --flags startup-clear --seccomp action=none --pid file=/tmp/tpm.pid --daemon
sleep 1
TPMDEV="swtpm:path=/tmp/tpm.sock"
cryptsetup luksFormat --batch-mode --type luks2 --cipher aes-xts-plain64 --key-size 512 \
  --pbkdf argon2id --uuid "$LUKS_UUID" --label THINCLIENT_ROOT "$ROOT" "$KEY"
cryptsetup open --key-file "$KEY" "$ROOT" tcroot
mkfs.ext4 -q -L THINCLIENT_ROOTFS /dev/mapper/tcroot

mkdir -p /mnt/t && mount /dev/mapper/tcroot /mnt/t
# The installed system = the Plan A image's root filesystem (kernel modules match the UKI).
cd /tmp && bsdtar -xf /iso live/filesystem.squashfs
unsquashfs -f -q -d /mnt/t live/filesystem.squashfs >/dev/null
mkdir -p /mnt/t/boot/efi && mount "$ESP" /mnt/t/boot/efi

cat > /mnt/t/etc/fstab <<EOF
/dev/mapper/root  /          ext4  defaults,noatime  0 1
LABEL=TCEFI       /boot/efi  vfat  umask=0077        0 2
EOF
# The TPM policy key systemd-cryptenroll binds PCR 11 to (public half only).
install -D -m 0644 /keys/pcr/tpm2-pcr-public.pem /mnt/t/etc/systemd/tpm2-pcr-public-key.pem

# TPM userspace for systemd-cryptenroll on the installed system.
mount --bind /proc /mnt/t/proc; mount --bind /sys /mnt/t/sys; mount --bind /dev /mnt/t/dev
cp /etc/resolv.conf /mnt/t/etc/resolv.conf
chroot /mnt/t bash -c 'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends tpm2-tools systemd-cryptsetup cryptsetup-bin >/dev/null'
umount /mnt/t/proc /mnt/t/sys /mnt/t/dev

# Seal into the target TPM with no PCR conditions (re-sealed properly at first boot),
# then destroy the install passphrase: from here on only that TPM opens the disk.
systemd-cryptenroll "$ROOT" --unlock-key-file="$KEY" --tpm2-device="$TPMDEV" --tpm2-pcrs= >/dev/null
systemd-cryptenroll "$ROOT" --unlock-tpm2-device="$TPMDEV" --wipe-slot=password >/dev/null
shred -u "$KEY"
cryptsetup luksDump "$ROOT" | grep -q systemd-tpm2 || { echo "TPM seal missing"; exit 1; }
kill "$(cat /tmp/tpm.pid)" 2>/dev/null || true
touch /mnt/t/etc/thinclient-tpm-firstboot      # tc-tpm-enroll re-seals, then removes it

# First boot: re-seal to Secure Boot state + our signed images, drop the temporary seal.
install -m 0755 /tools/tc-tpm-enroll /mnt/t/usr/local/sbin/tc-tpm-enroll
cat > /mnt/t/etc/systemd/system/tc-tpm-enroll.service <<EOF
[Unit]
Description=Thin Client: seal the disk key into the TPM (first boot)
ConditionPathExists=/etc/thinclient-tpm-firstboot
After=local-fs.target
Before=display-manager.service lightdm.service

[Service]
Type=oneshot
Environment=LUKS_DEV=/dev/disk/by-uuid/$LUKS_UUID
ExecStart=/usr/local/sbin/tc-tpm-enroll

[Install]
WantedBy=multi-user.target
EOF
ln -sf /etc/systemd/system/tc-tpm-enroll.service /mnt/t/etc/systemd/system/multi-user.target.wants/tc-tpm-enroll.service

# ESP: Microsoft-signed shim, MokManager, our signed UKI as shim's second stage, and
# our PUBLIC boot certificate for "Enroll key from disk".
mkdir -p /mnt/t/boot/efi/EFI/BOOT
cp /usr/lib/shim/shimx64.efi.signed /mnt/t/boot/efi/EFI/BOOT/BOOTX64.EFI
cp /usr/lib/shim/mmx64.efi.signed   /mnt/t/boot/efi/EFI/BOOT/mmx64.efi
cp "$UKI"                           /mnt/t/boot/efi/EFI/BOOT/grubx64.efi
cp /keys/secureboot/MOK.der         /mnt/t/boot/efi/THINCLIENT-ENROLL-ME.der
sync
echo "disk ready: $OUT  (LUKS $LUKS_UUID, kernel $KVER)"
