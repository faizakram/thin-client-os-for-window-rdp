#!/usr/bin/env bash
# =============================================================================
#  ThinClient OS — Install-to-disk
#  Installed to: /opt/thinclient/bin/thinclient-install
#
#  Persists the running live appliance onto an internal disk so the machine
#  boots the thin client from local storage (no USB needed). Run this ONCE on
#  a reference machine, then clone the fleet with Clonezilla (docs/CLONEZILLA.md).
#
#  What it does:
#    1. Partitions the target disk: GPT + 512M EFI (FAT32) + rest ext4 root.
#    2. rsyncs the live root filesystem onto the new root.
#    3. Generates /etc/fstab, removes live-only packages, installs GRUB
#       (UEFI and BIOS), and rebuilds the initramfs.
#
#  DESTRUCTIVE: everything on the chosen disk is erased. You are asked to type
#  the disk name to confirm.
#
#  Usage:
#     sudo thinclient-install [/dev/sdX]     # interactive if disk omitted
# =============================================================================
set -euo pipefail

TARGET_MNT="/mnt/target"
LOG="/var/log/thinclient/install.log"

log() { printf '%s [install] %s\n' "$(date --iso-8601=seconds 2>/dev/null || date)" "$*" | tee -a "$LOG"; }
die() { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }
# Success / warning counterparts to log(). These MUST exist here: the script runs
# under `set -e`, so calling an undefined helper is exit 127 and kills the install.
ok()   { printf '\033[1;32m[OK]\033[0m %s\n' "$*" | tee -a "$LOG"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n'  "$*" | tee -a "$LOG" >&2; }

[[ "$(id -u)" -eq 0 ]] || die "Run as root: sudo thinclient-install"
mkdir -p "$(dirname "$LOG")"

# --------------------------------------------------------------------------- #
# 1. Choose the target disk.
# --------------------------------------------------------------------------- #
DISK="${1:-}"
if [[ -z "$DISK" ]]; then
  echo "Available disks:"
  lsblk -d -o NAME,SIZE,MODEL,TYPE | grep -E 'disk$' || true
  echo
  read -r -p "Target disk to ERASE and install onto (e.g. /dev/sda): " DISK
fi
[[ -b "$DISK" ]] || die "Not a block device: $DISK"

# Refuse to install onto the live boot medium itself.
LIVE_SRC="$(findmnt -no SOURCE /run/live/medium 2>/dev/null || true)"
if [[ -n "$LIVE_SRC" && "$LIVE_SRC" == "$DISK"* ]]; then
  die "$DISK appears to be the live boot medium. Choose the internal disk."
fi

echo
echo "  !!  ALL DATA ON ${DISK} WILL BE DESTROYED  !!"
lsblk "$DISK" || true
echo
read -r -p "Type the disk name (${DISK}) to confirm: " CONFIRM
[[ "$CONFIRM" == "$DISK" ]] || die "Confirmation did not match. Aborting."

# --------------------------------------------------------------------------- #
# 1a. Encrypted install (security plan Phase B) — decided BEFORE anything is erased.
#
#     An image that carries the signed boot image (/opt/thinclient/phaseb) installs
#     ENCRYPTED: LUKS2 root, key sealed into this machine's TPM, Secure Boot. That needs
#     UEFI + Secure Boot on + a TPM 2.0. A machine without them is REFUSED (decision
#     2026-10-03), unless the installer is started with TC_ALLOW_UNENCRYPTED=1 and the
#     exception is typed out — then it installs unencrypted and the manager is told.
# --------------------------------------------------------------------------- #
PHASEB=/opt/thinclient/phaseb
ENCRYPT=0; UNENCRYPTED_EXCEPTION=0
TPM2_DEVICE="${TC_TPM2_DEVICE:-auto}"      # a test harness points this at a software TPM
if [[ -f "$PHASEB/thinclient.efi" ]]; then
  why=()
  if [[ "${TC_INSTALL_TEST:-0}" != "1" ]]; then
    [[ -d /sys/firmware/efi ]] || why+=("the machine did not start in UEFI mode (switch off Legacy/CSM boot)")
    sb="$(od -An -t u1 -j4 -N1 /sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-e0f84a3cb4bd 2>/dev/null | tr -d ' ')"
    [[ "$sb" == "1" ]] || why+=("Secure Boot is not switched on in the BIOS")
    { [[ -e /dev/tpmrm0 ]] && [[ "$(cat /sys/class/tpm/tpm0/tpm_version_major 2>/dev/null)" == "2" ]]; } \
      || why+=("no TPM 2.0 was found (absent, or switched off in the BIOS)")
  fi
  if ((${#why[@]} == 0)); then
    ENCRYPT=1
    ok "Encrypted install: UEFI, Secure Boot and TPM 2.0 found"
  else
    echo
    echo "  This image installs ENCRYPTED, and this machine can't be encrypted:"
    printf '    - %s\n' "${why[@]}"
    echo "  Fix it in the BIOS and run 'sudo thinclient-install' again. ${DISK} has NOT been changed."
    if [[ "${TC_ALLOW_UNENCRYPTED:-0}" == "1" ]]; then
      read -r -p "  To install WITHOUT encryption anyway, type INSTALL UNENCRYPTED: " _ans
      [[ "$_ans" == "INSTALL UNENCRYPTED" ]] || die "Not confirmed. ${DISK} has NOT been changed."
      warn "Installing UNENCRYPTED by explicit exception — the manager will show it"
      UNENCRYPTED_EXCEPTION=1
    else
      exit 1
    fi
  fi
fi

# Device name shown in the Manager dashboard (optional; agent falls back to the
# hostname if left blank). Collected now, written to the target after the copy.
echo
# Require a device name so the machine shows up in the dashboard by a real name
# instead of the default hostname. Loop until something non-empty is entered, and
# echo it back so the installer can SEE it was captured.
DEVNAME=""
while [[ -z "$DEVNAME" ]]; do
  read -r -p "Device name for the dashboard (e.g. Reception-PC): " DEVNAME || true
  DEVNAME="$(printf '%s' "${DEVNAME:-}" | tr -d '\r' | sed 's/^ *//; s/ *$//')"
  [[ -z "$DEVNAME" ]] && echo "  A device name is required — please type one."
done
echo "  ✓ Device name set to: ${DEVNAME}"

# Partition suffix: /dev/sda -> sda1 ; /dev/nvme0n1 -> nvme0n1p1
part() { case "$DISK" in *[0-9]) echo "${DISK}p${1}";; *) echo "${DISK}${1}";; esac; }
EFI_PART="$(part 1)"; ROOT_PART="$(part 2)"

# --------------------------------------------------------------------------- #
# 1b. Identity + approval — deliberately BEFORE anything is erased.
#
#     Approval has to be settled while the target disk is still intact. Asking
#     afterwards (as this used to) meant a refusal arrived when the disk had
#     already been wiped and written — destroying the machine's previous contents
#     for an install that was never allowed to finish.
#
#     The identity is generated here too, because hwid = sha256(machine-id) and the
#     approval is bound to it. It's just random bytes, so it needs no disk.
# --------------------------------------------------------------------------- #
# Generated with NO external binaries where possible. The kernel's uuid file plus
# bash string substitution needs nothing read off the install medium — a failing or
# badly-written USB stick was throwing "od: Input/output error" here, which stopped
# the install before it began. Fallbacks cover an unusual kernel.
NEW_MACHINE_ID=""
if [[ -r /proc/sys/kernel/random/uuid ]]; then
  read -r _uuid < /proc/sys/kernel/random/uuid
  NEW_MACHINE_ID="${_uuid//-/}"
fi
if [[ "${#NEW_MACHINE_ID}" -ne 32 ]]; then
  NEW_MACHINE_ID="$(systemd-id128 new 2>/dev/null | tr -d '\n' || true)"
fi
if [[ "${#NEW_MACHINE_ID}" -ne 32 ]]; then
  echo
  echo "  Could not generate a machine identity."
  echo
  echo "  This usually means the USB stick cannot be read reliably. Re-write the"
  echo "  image (balenaEtcher verifies what it wrote), ideally onto a different stick."
  echo
  exit 1
fi
# Must match thinclient-agent's device_id(): sha256(machine-id)[:32]
DEVICE_HWID="$(printf '%s' "$NEW_MACHINE_ID" | sha256sum | cut -c1-32)"

# The live system carries the tenant's baked config; the target doesn't exist yet.
LIVE_CONF="/etc/thinclient/license.conf"
CTRL_URL="$(sed -n 's/^CONTROL_URL=//p'  "$LIVE_CONF" 2>/dev/null | head -1 | tr -d '\r')"
TEN_TOKEN="$(sed -n 's/^TENANT_TOKEN=//p' "$LIVE_CONF" 2>/dev/null | head -1 | tr -d '\r')"
ENROLL_CREDS=""

if [[ -n "$CTRL_URL" && -n "$TEN_TOKEN" ]]; then
  ENROLL_BIN="/opt/thinclient/bin/thinclient-enroll"
  [[ -x "$ENROLL_BIN" ]] || ENROLL_BIN="$(dirname "$0")/../scripts/thinclient-enroll"
  if [[ -x "$ENROLL_BIN" ]]; then
    # Wait for the manager to be genuinely reachable before asking for approval.
    # A freshly-booted live session often has an interface up but no working path
    # out yet (DHCP, DNS, a slow switch port), and failing at that moment reads to
    # the operator as "the installer is broken" rather than "the network isn't ready".
    # Shell expansion, not sed: `\?` in a BRE is a GNU extension, so a sed-based
    # parse silently yields "https" on any non-GNU sed. Strip scheme, then path,
    # then port.
    MGR_HOST="${CTRL_URL#*://}"; MGR_HOST="${MGR_HOST%%/*}"; MGR_HOST="${MGR_HOST%%:*}"
    log "Waiting for the manager (${MGR_HOST}) to be reachable"
    NET_OK=0
    NET_TRIES=12
    for _i in $(seq 1 "$NET_TRIES"); do
      # `timeout` as well as --max-time: curl's own timeouts are enforced inside its
      # transfer loop, so a blocking name lookup can outlive --max-time entirely. An
      # operator then sees one frozen line for minutes with no way to tell whether
      # the installer is working or dead. The outer bound makes that impossible.
      if timeout 12 curl -s -o /dev/null --max-time 8 --connect-timeout 5 \
           "${CTRL_URL}/login" 2>/dev/null; then
        NET_OK=1; break
      fi
      # Say something on EVERY attempt. Silence is what made this look like a hang —
      # the check could run nearly three minutes without printing a character, and
      # that is precisely when somebody power-cycles a machine mid-install.
      printf '    attempt %d of %d — no reply from %s yet\n' "$_i" "$NET_TRIES" "$MGR_HOST"
      sleep 6
    done
    if [[ "$NET_OK" -eq 0 ]]; then
      echo
      echo "  Cannot reach ${MGR_HOST} from this machine."
      echo
      echo "  Network check:"
      ip -4 -o addr show scope global 2>/dev/null | awk '{printf "    address : %s on %s\n", $4, $2}' || true
      ip route show default 2>/dev/null | awk '{printf "    gateway : %s via %s\n", $3, $5}' || true
      if getent hosts "$MGR_HOST" >/dev/null 2>&1; then
        echo "    dns     : OK ($(getent hosts "$MGR_HOST" | awk '{print $1}' | head -1))"
      else
        echo "    dns     : FAILED to resolve ${MGR_HOST}  <- check DNS / captive portal"
      fi
      if timeout 8 bash -c "exec 3<>/dev/tcp/${MGR_HOST}/443" 2>/dev/null; then
        echo "    port 443: reachable, but no HTTPS reply  <- a firewall or proxy is filtering it"
      else
        echo "    port 443: BLOCKED or unreachable  <- check the cable, VLAN or firewall"
      fi
      echo
      echo "  ${DISK} has NOT been touched yet."
      echo
      # A dead end here is worse than it looks: the machine is already on someone's
      # desk, and refusing to install leaves them with nothing while the network is
      # investigated. Installing is safe to allow, because it grants nothing — an
      # unregistered machine still has to ASK to join and still has to be approved
      # before it receives any credentials. So offer the choice instead of deciding.
      echo "  You can still install now. The machine will ask to join the fleet the"
      echo "  first time it has a working network, and you approve it then — exactly"
      echo "  as you would today. Nothing is granted without that approval."
      echo
      # Read from the console if there is one, otherwise from stdin. Binding only to
      # /dev/tty means that wherever it is absent the question cannot be answered at
      # all and the operator is refused whatever they wanted.
      _off=""
      if [[ -r /dev/tty ]]; then
        read -r -p "  Install anyway, and join the fleet later? [y/N] " _off < /dev/tty || _off=""
      else
        read -r -p "  Install anyway, and join the fleet later? [y/N] " _off || _off=""
      fi
      case "$_off" in
        [yY]|[yY][eE][sS])
          warn "Installing without contacting the manager — this machine must be approved later"
          rm -f "$ENROLL_CREDS"; ENROLL_CREDS=""
          NET_OK=2   # continue, but skip the approval step entirely
          ;;
        *)
          echo
          echo "  Nothing has been changed — ${DISK} is untouched."
          echo "  Fix the network and run 'sudo thinclient-install' again."
          echo
          exit 1
          ;;
      esac
    fi
    if [[ "$NET_OK" -eq 2 ]]; then
      log "Skipping the approval step — this machine will register when it first gets a network"
    else
    ok "Manager reachable"
    log "Checking whether this machine needs approval before installing"
    ENROLL_CREDS="$(mktemp)"
    set +e
    # Token via the ENVIRONMENT, never argv: /proc/<pid>/cmdline is world-readable.
    TC_TENANT_TOKEN="$TEN_TOKEN" \
    "$ENROLL_BIN" --url "$CTRL_URL" --hwid "$DEVICE_HWID" \
                  --name "${DEVNAME:-}" --hostname "$(hostname 2>/dev/null || true)" \
                  --disk "$DISK" --out "$ENROLL_CREDS"
    ENROLL_RC=$?
    set -e
    case "$ENROLL_RC" in
      0) log "Machine approved — continuing with the installation" ;;
      3) log "This account does not require approval — the device will register itself on first boot"
         rm -f "$ENROLL_CREDS"; ENROLL_CREDS="" ;;
      *)
         rm -f "$ENROLL_CREDS"
         echo
         echo "  Installation cancelled: this machine was not approved."
         echo
         echo "  NOTHING has been changed — ${DISK} has not been touched and still"
         echo "  holds whatever was on it before. Ask your administrator to approve"
         echo "  this machine, then run 'sudo thinclient-install' again."
         echo
         exit 1
         ;;
    esac
    fi   # end: manager was reachable (NET_OK -ne 2)
  else
    log "WARNING: thinclient-enroll not found — skipping the approval step"
  fi
else
  log "No tenant token in this image — the device will not join a fleet automatically"
fi

# --------------------------------------------------------------------------- #
# 2. Partition + format.
# --------------------------------------------------------------------------- #
# Release the target disk before touching it.
#
# `umount -R "$TARGET_MNT"` only ever released the installer's OWN mount point, never the
# disk being installed to — so an install onto a machine that already had an operating
# system died on:
#
#     wipefs: error: /dev/sda: probing initialization failed: Device or resource busy
#
# which tells the person standing at the machine nothing at all. A live boot routinely
# holds the target disk: the desktop auto-mounts its partitions, a swap partition is
# activated, or an LVM group / RAID array on it is assembled during boot. Each of those
# keeps the whole block device open, and each needs a different command to let go.
release_disk() {
  local disk="$1"

  # Swap first. A swap partition holds the device open and umount will not touch it, so
  # doing this second would leave the disk busy after everything else had been released.
  # Overridable ONLY so the release order can be exercised off a real Linux box. It
  # defaults to the real file and nothing in the installer ever sets it.
  if [[ -r "${TC_SWAPS_FILE:-/proc/swaps}" ]]; then
    local sdev
    while read -r sdev _; do
      [[ "$sdev" == "$disk"* ]] && { swapoff "$sdev" 2>/dev/null || true; }
    done < <(tail -n +2 "${TC_SWAPS_FILE:-/proc/swaps}")
  fi

  # Unmount every mounted partition of this disk, deepest path first so a nested mount
  # (/mnt/x and /mnt/x/boot) comes off in the right order.
  local mp
  while read -r mp; do
    [[ -n "$mp" && "$mp" != "[SWAP]" ]] && { umount -R "$mp" 2>/dev/null || umount -l "$mp" 2>/dev/null || true; }
  done < <(lsblk -nrpo MOUNTPOINT "$disk" 2>/dev/null | grep -v '^$' | sort -r)

  # An LVM group or RAID array built on this disk keeps it open through device-mapper,
  # and no amount of unmounting releases it — the mapping itself has to go.
  if command -v vgchange >/dev/null 2>&1; then vgchange -an >/dev/null 2>&1 || true; fi
  if command -v mdadm >/dev/null 2>&1; then mdadm --stop --scan >/dev/null 2>&1 || true; fi
  if command -v dmsetup >/dev/null 2>&1; then
    local h
    for h in /sys/block/"$(basename "$disk")"/holders/*; do
      [[ -e "$h" ]] && dmsetup remove "$(basename "$h")" >/dev/null 2>&1 || true
    done
  fi

  udevadm settle 2>/dev/null || true
}

# Is anything still holding it? Checked explicitly so the failure can NAME the holder
# rather than surfacing a wipefs error nobody can act on.
disk_holders() {
  local disk="$1" out=""
  local mounts; mounts="$(lsblk -nrpo NAME,MOUNTPOINT "$disk" 2>/dev/null | awk 'NF>1 {printf "    %s is mounted at %s\n", $1, $2}')"
  [[ -n "$mounts" ]] && out+="$mounts"
  local sw; sw="$(awk -v d="$disk" 'NR>1 && index($1,d)==1 {printf "    %s is in use as swap\n", $1}' "${TC_SWAPS_FILE:-/proc/swaps}" 2>/dev/null)"
  [[ -n "$sw" ]] && out+="$sw"
  local hd
  for hd in /sys/block/"$(basename "$disk")"/holders/*; do
    [[ -e "$hd" ]] && out+="    held by $(basename "$hd") (RAID or LVM)\n"
  done
  printf '%b' "$out"
}

log "Partitioning ${DISK} (EFI=${EFI_PART}, root=${ROOT_PART})"
umount -R "$TARGET_MNT" 2>/dev/null || true
log "Releasing ${DISK} (unmounting partitions, swap off, RAID/LVM down)"
release_disk "$DISK"

if ! wipefs -a "$DISK" 2>/dev/null; then
  # Second attempt: a udev rule or a desktop automounter can re-take a disk the moment
  # it is released, so one retry after settling turns a race into a non-event.
  sleep 2; release_disk "$DISK"
  if ! wipefs -a "$DISK"; then
    echo
    echo "  Cannot write to ${DISK} — something on this machine is still using it."
    echo
    local_holders="$(disk_holders "$DISK")"
    if [[ -n "$local_holders" ]]; then
      echo "  Still in use by:"
      printf '%s' "$local_holders"
    else
      echo "  Nothing obvious is holding it, which usually means the disk is failing"
      echo "  or is read-only (a hardware write-protect jumper, or a dying SSD)."
    fi
    echo
    echo "  ${DISK} has NOT been changed. Shut down, remove any other drive you do not"
    echo "  want touched, and run 'sudo thinclient-install' again."
    echo
    exit 1
  fi
fi
sgdisk --zap-all "$DISK"
ROOT_DEV="$ROOT_PART"
if [[ "$ENCRYPT" == "1" ]]; then
  # ESP 1 GiB (label TCEFI: holds shim + the signed boot image) + a LUKS2 root with
  # the "Linux root (x86-64)" type.
  sgdisk -n1:0:+1G -t1:ef00 -c1:"TCEFI" "$DISK"
  sgdisk -n2:0:0   -t2:8304 -c2:"THINCLIENT_ROOT" "$DISK"
  partprobe "$DISK"; sleep 2

  log "Formatting: boot partition + encrypted root (LUKS2, AES-256-XTS)"
  mkfs.vfat -F32 -n TCEFI "$EFI_PART"
  LUKS_UUID="$(cat "$PHASEB/LUKS_UUID")"
  # A random passphrase exists only for the minutes of this install, in RAM.
  INSTALL_KEY="$(mktemp -p /dev/shm)"; head -c 64 /dev/urandom >"$INSTALL_KEY"
  cryptsetup luksFormat --batch-mode --type luks2 --cipher aes-xts-plain64 --key-size 512 \
    --pbkdf argon2id --uuid "$LUKS_UUID" --label THINCLIENT_ROOT "$ROOT_PART" "$INSTALL_KEY"
  # Our own mapping name, and a stale one from an earlier failed attempt in this live
  # session is closed first (cryptsetup refuses an existing name: exit 5). The INSTALLED
  # system calls it "root" — the signed boot image's command line says so.
  MAPPER=tc-install-root
  cryptsetup close "$MAPPER" 2>/dev/null || true
  cryptsetup open --key-file "$INSTALL_KEY" "$ROOT_PART" "$MAPPER"
  ROOT_DEV="/dev/mapper/$MAPPER"
  mkfs.ext4 -F -L TCROOT "$ROOT_DEV"

  # Seal the key into THIS machine's TPM — no PCR conditions yet, because this live
  # system boots through a different chain than the installed one. First boot re-seals
  # it to Secure Boot + our signed boot images and wipes this seal (tc-tpm-enroll).
  # Then the install passphrase goes: from here on only this TPM opens the disk.
  log "Sealing the disk key into this machine's TPM"
  systemd-cryptenroll "$ROOT_PART" --unlock-key-file="$INSTALL_KEY" --tpm2-device="$TPM2_DEVICE" --tpm2-pcrs= \
    || die "Could not seal the key into the TPM. Is the TPM switched on in the BIOS?"
  systemd-cryptenroll "$ROOT_PART" --unlock-tpm2-device="$TPM2_DEVICE" --wipe-slot=password \
    || die "Could not remove the install passphrase"
  shred -u "$INSTALL_KEY"
  cryptsetup luksDump "$ROOT_PART" | grep -q systemd-tpm2 || die "No TPM seal on the disk — aborting"
  ok "Disk key sealed into the TPM; no password exists for this disk"
else
  sgdisk -n1:0:+512M -t1:ef00 -c1:"EFI" "$DISK"
  sgdisk -n2:0:0     -t2:8300 -c2:"THINCLIENT_ROOT" "$DISK"
  partprobe "$DISK"; sleep 2

  log "Formatting partitions"
  mkfs.vfat -F32 -n EFI "$EFI_PART"
  mkfs.ext4 -F -L THINCLIENT_ROOT "$ROOT_PART"
fi

# --------------------------------------------------------------------------- #
# 3. Mount + copy the live root filesystem.
# --------------------------------------------------------------------------- #
log "Mounting target"
mkdir -p "$TARGET_MNT"
mount "$ROOT_DEV" "$TARGET_MNT"
mkdir -p "$TARGET_MNT/boot/efi"
mount "$EFI_PART" "$TARGET_MNT/boot/efi"

log "Copying system (rsync) — this takes a few minutes"
rsync -aHAXx --info=progress2 \
  --exclude=/dev/* --exclude=/proc/* --exclude=/sys/* --exclude=/tmp/* \
  --exclude=/run/* --exclude=/mnt/* --exclude=/media/* --exclude=/lost+found \
  --exclude=/live --exclude="/run/live" --exclude="/lib/live/mount" \
  --exclude=/var/log/thinclient/* \
  / "$TARGET_MNT/"

# --------------------------------------------------------------------------- #
# 3b. Per-machine identity. Installing the same USB onto several machines must
#     NOT give them all the live medium's machine-id (identical hwid -> the
#     manager folds them into ONE device), so each install gets its own.
#
#     We GENERATE it here rather than blanking the file and letting first boot do
#     it, because the approval flow below has to bind to this machine's final
#     hwid — and that hwid is sha256(machine-id). Deferring it would mean
#     approving an identity that doesn't exist yet.
#
#     thinclient-firstboot still regenerates the id if the hardware fingerprint
#     later changes (a cloned disk), which correctly forces re-approval.
# --------------------------------------------------------------------------- #
# NEW_MACHINE_ID / DEVICE_HWID were generated in §1b, before the disk was touched,
# because the approval is bound to this hwid. Here we only persist it.
log "Assigning the unique per-device identity"
printf '%s\n' "$NEW_MACHINE_ID" >"$TARGET_MNT/etc/machine-id"
rm -f "$TARGET_MNT/var/lib/dbus/machine-id" \
      "$TARGET_MNT/var/lib/thinclient/.hwfp" 2>/dev/null || true
ln -sf /etc/machine-id "$TARGET_MNT/var/lib/dbus/machine-id" 2>/dev/null || true

# --------------------------------------------------------------------------- #
# 3c. Persist the approved credentials NOW, not at the end.
#
#     Learned the hard way: the credential write used to sit after the chroot /
#     GRUB stage, and when anything there aborted the script the machine was left
#     bootable but unactivated — no device name, no credentials — which looks like
#     a successful install and then shows up as a permanently offline device.
#     The target is mounted and its /etc/thinclient exists as soon as the copy is
#     done, so there is no reason to wait.
# --------------------------------------------------------------------------- #
TCONF="$TARGET_MNT/etc/thinclient/license.conf"
tc_set_key() {  # <key> <value> — replace or append in the target's license.conf
  local k="$1" v="$2"
  [[ -n "$v" ]] || return 0
  mkdir -p "$(dirname "$TCONF")"; touch "$TCONF"
  if grep -q "^${k}=" "$TCONF"; then sed -i "s#^${k}=.*#${k}=${v}#" "$TCONF"; else printf '%s=%s\n' "$k" "$v" >>"$TCONF"; fi
}

if [[ -n "${ENROLL_CREDS:-}" && -s "${ENROLL_CREDS}" ]]; then
  log "Writing this device's fleet credentials"
  tc_set_key ENROLL_CODE   "$(sed -n 's/^ENROLL_CODE=//p'   "$ENROLL_CREDS" | head -1 | tr -d '\r')"
  tc_set_key DEVICE_SECRET "$(sed -n 's/^DEVICE_SECRET=//p' "$ENROLL_CREDS" | head -1 | tr -d '\r')"
  tc_set_key LICENSE_ENFORCE "true"
  shred -u "$ENROLL_CREDS" 2>/dev/null || rm -f "$ENROLL_CREDS"
  ENROLL_CREDS=""
  ok "Credentials stored — this device is activated"
fi

# Device name too: it is what identifies the machine in the dashboard, and it was
# being lost for exactly the same reason.
if [[ -n "${DEVNAME:-}" ]]; then
  log "Setting device name: ${DEVNAME}"
  tc_set_key DEVICE_NAME "$DEVNAME"
  HN="$(printf '%s' "$DEVNAME" | tr ' ' '-' | tr -cd 'A-Za-z0-9-' | sed 's/^-*//; s/-*$//' | cut -c1-63)"
  if [[ -n "$HN" ]]; then
    echo "$HN" >"$TARGET_MNT/etc/hostname"
    if [[ -f "$TARGET_MNT/etc/hosts" ]] && grep -q '^127\.0\.1\.1' "$TARGET_MNT/etc/hosts"; then
      sed -i "s#^127\.0\.1\.1.*#127.0.1.1\t${HN}#" "$TARGET_MNT/etc/hosts"
    fi
  fi
fi

# --------------------------------------------------------------------------- #
# 4. fstab.
# --------------------------------------------------------------------------- #
log "Writing /etc/fstab"
if [[ "$ENCRYPT" == "1" ]]; then
  # The signed boot image opens the LUKS root as /dev/mapper/root before this runs.
  ROOT_SPEC="/dev/mapper/root"; EFI_SPEC="LABEL=TCEFI"
else
  ROOT_SPEC="UUID=$(blkid -s UUID -o value "$ROOT_PART")"; EFI_SPEC="UUID=$(blkid -s UUID -o value "$EFI_PART")"
fi
cat >"$TARGET_MNT/etc/fstab" <<EOF
# ThinClient OS — generated by thinclient-install
${ROOT_SPEC}  /          ext4  errors=remount-ro,noatime  0 1
${EFI_SPEC}   /boot/efi  vfat  umask=0077                 0 1
# /tmp is tmpfs (RAM): recording segments are staged here for the seconds between
# ffmpeg writing them and S3 confirming the upload, then deleted. Pin the size —
# tmpfs otherwise defaults to HALF of physical memory, which on a small machine is
# room enough to starve the session. 512M is ~4600 segments, far above the agent's
# own backlog cap, so this bounds the worst case without ever being the binding limit.
tmpfs              /tmp       tmpfs defaults,nosuid,nodev,size=512m  0 0
EOF

# --------------------------------------------------------------------------- #
# 5. Chroot: drop live packages, install GRUB, rebuild initramfs.
# --------------------------------------------------------------------------- #
log "Preparing chroot"
# --rbind (recursive) so nested mounts come along — in particular
# /sys/firmware/efi/efivars, without which grub-install/efibootmgr cannot
# register the UEFI NVRAM boot entry ("EFI variables cannot be set on this
# system"). Cleanup below uses `umount -R`, which handles the nested mounts.
for fs in dev dev/pts proc sys run; do
  mkdir -p "$TARGET_MNT/$fs"
  mount --rbind "/$fs" "$TARGET_MNT/$fs"
done

UEFI_MODE=0; [[ -d /sys/firmware/efi ]] && UEFI_MODE=1

log "Installing bootloader inside chroot (UEFI_MODE=${UEFI_MODE})"
CHROOT_LOG="$(mktemp)"
set +e
chroot "$TARGET_MNT" /bin/bash -uo pipefail 2>&1 <<CHROOT | tee "$CHROOT_LOG"
export DEBIAN_FRONTEND=noninteractive

# Remove live-only components so it boots as a normal installed system.
apt-get -y purge live-boot live-boot-initramfs-tools live-config live-config-systemd 2>/dev/null || true
apt-get -y autoremove 2>/dev/null || true

if [ "${ENCRYPT}" != "1" ]; then
# GRUB defaults: silent, kiosk-friendly kernel command line.
# Live images don't ship /etc/default/grub — create it so the tweaks below apply
# (otherwise sed/grep error out and the boot stays verbose).
if [ ! -f /etc/default/grub ]; then
  cat >/etc/default/grub <<'GRUBDEF'
GRUB_DEFAULT=0
GRUB_TIMEOUT=1
GRUB_DISTRIBUTOR="ThinClient"
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"
GRUB_CMDLINE_LINUX=""
GRUBDEF
fi
# usbcore.autosuspend=-1: never power-manage USB on this appliance. A suspended
# webcam that fails to resume drops off the bus (-71/EPROTO) and the recording
# silently loses its camera track until somebody replugs it; the machine is
# mains-powered at a desk, so there is nothing to save. This is the ONE part of the
# camera fix that cannot ship over the air — it needs update-grub and a reboot — so
# the agent also sets the same default at runtime for the existing fleet.
sed -i 's|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT="quiet splash loglevel=0 vt.global_cursor_default=0 rd.systemd.show_status=false systemd.show_status=false usbcore.autosuspend=-1"|' /etc/default/grub || true
sed -i 's|^GRUB_TIMEOUT=.*|GRUB_TIMEOUT=1|' /etc/default/grub || true
grep -q '^GRUB_TIMEOUT_STYLE' /etc/default/grub || echo 'GRUB_TIMEOUT_STYLE=hidden' >> /etc/default/grub
# os-prober scans EVERY disk it can see - including the installer's own USB - and is a
# well-known way for update-grub to fail or hang. An appliance boots one OS, so there
# is nothing for it to find and no reason to run it.
grep -q '^GRUB_DISABLE_OS_PROBER' /etc/default/grub || echo 'GRUB_DISABLE_OS_PROBER=true' >> /etc/default/grub

# UEFI bootloader. Two installs:
#   1. Named entry — registers an NVRAM boot option WHEN efivars are writable.
#   2. --removable — writes the firmware fallback path /EFI/BOOT/BOOTX64.EFI so
#      the machine boots even when the installer chroot can't set NVRAM (the
#      common "EFI variables cannot be set on this system" case). This is what
#      makes an appliance install boot reliably on any UEFI board.
if [ "${UEFI_MODE}" = "1" ]; then
  grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=thinclient --recheck || true
  grub-install --target=x86_64-efi --efi-directory=/boot/efi --removable --recheck || true
fi
# BIOS bootloader (best-effort; this GPT layout has no bios_grub partition, so on
# UEFI machines it simply no-ops — expected, not an error).
grub-install --target=i386-pc --recheck ${DISK} || true

# These were UNGUARDED, and that was the real fault behind three separate
# failures: the chroot runs with -e, so one non-zero exit here aborted the whole
# installer - skipping the activation steps AND, worse, leaving no grub.cfg, which
# is a disk that cannot boot. Now each has a fallback and cannot kill the run;
# the outer script verifies the RESULT instead of trusting the exit code.
update-grub || grub-mkconfig -o /boot/grub/grub.cfg || echo "WARN: grub config generation failed"
update-initramfs -u -k all || update-initramfs -u || echo "WARN: initramfs rebuild failed"
fi   # ENCRYPT: no GRUB at all — it would overwrite shim on the ESP; the signed boot
     # image carries the kernel, initrd and command line (copied in after the chroot).

# Make sure the CURRENT services are enabled on the installed system.
# (The display path is LightDM now — the old thinclient-x.service must stay off,
# or it fights LightDM for the screen.)
systemctl set-default graphical.target || echo "WARN: could not set the default target"
systemctl disable thinclient-x.service thinclient-session.service 2>/dev/null || true
systemctl enable lightdm.service thinclient-firstboot.service thinclient-watchdog.service \
                 thinclient-agent.service thinclient-provision.service \
                 NetworkManager.service NetworkManager-wait-online.service 2>/dev/null || true
systemctl enable thinclient-update.timer 2>/dev/null || true
CHROOT
CHROOT_RC=${PIPESTATUS[0]}
set -e
if [[ "$CHROOT_RC" -ne 0 ]]; then
  warn "The bootloader stage reported errors (exit ${CHROOT_RC}). Checking what landed…"
  grep -iE "^WARN|error|failed" "$CHROOT_LOG" | tail -8 | sed 's/^/    /' || true
fi

# --------------------------------------------------------------------------- #
# 5a. Is this disk actually bootable?
#
#     An install that finishes without a grub.cfg produces a machine that will
#     not boot once the USB is removed. That must be a hard, obvious failure —
#     never something the operator discovers by unplugging the stick.
# --------------------------------------------------------------------------- #
BOOT_OK=1
if [[ "$ENCRYPT" == "1" ]]; then
  # Boot chain on the ESP: Microsoft-signed shim -> our signed boot image (shim's second
  # stage) -> TPM unlock. MokManager is next to shim, and our PUBLIC certificate is on
  # the ESP for the one-time "Enroll key from disk" at the first power-on.
  log "Installing the signed boot chain"
  E="$TARGET_MNT/boot/efi"
  mkdir -p "$E/EFI/BOOT"
  cp /usr/lib/shim/shimx64.efi.signed "$E/EFI/BOOT/BOOTX64.EFI"
  cp /usr/lib/shim/mmx64.efi.signed   "$E/EFI/BOOT/mmx64.efi"
  cp "$PHASEB/thinclient.efi"         "$E/EFI/BOOT/grubx64.efi"
  cp "$PHASEB/MOK.der"                "$E/THINCLIENT-ENROLL-ME.der"
  efibootmgr -c -d "$DISK" -p 1 -L "ThinClient" -l '\EFI\BOOT\BOOTX64.EFI' >/dev/null 2>&1 || true

  # First boot: re-seal to Secure Boot + our signed boot images, wipe the install seal.
  install -D -m 0644 "$PHASEB/tpm2-pcr-public-key.pem" "$TARGET_MNT/etc/systemd/tpm2-pcr-public-key.pem"
  install -D -m 0755 "$PHASEB/tc-tpm-enroll" "$TARGET_MNT/usr/local/sbin/tc-tpm-enroll"
  cat >"$TARGET_MNT/etc/systemd/system/tc-tpm-enroll.service" <<UNIT
[Unit]
Description=Thin Client: seal the disk key to Secure Boot + signed boot images (first boot)
ConditionPathExists=/etc/thinclient-tpm-firstboot
After=local-fs.target
Before=display-manager.service lightdm.service

[Service]
Type=oneshot
Environment=LUKS_DEV=/dev/disk/by-uuid/$LUKS_UUID
ExecStart=/usr/local/sbin/tc-tpm-enroll

[Install]
WantedBy=multi-user.target
UNIT
  ln -sf /etc/systemd/system/tc-tpm-enroll.service "$TARGET_MNT/etc/systemd/system/multi-user.target.wants/tc-tpm-enroll.service"
  touch "$TARGET_MNT/etc/thinclient-tpm-firstboot"
  mkdir -p "$TARGET_MNT/etc/thinclient"; echo "encrypted=1" >"$TARGET_MNT/etc/thinclient/install-generation"

  for f in EFI/BOOT/BOOTX64.EFI EFI/BOOT/mmx64.efi EFI/BOOT/grubx64.efi THINCLIENT-ENROLL-ME.der; do
    [[ -s "$E/$f" ]] || { BOOT_OK=0; warn "MISSING $f on the boot partition"; }
  done
else
  [[ -s "$TARGET_MNT/boot/grub/grub.cfg" ]] || { BOOT_OK=0; warn "MISSING /boot/grub/grub.cfg"; }
  if [[ "$UEFI_MODE" = "1" ]]; then
    ls "$TARGET_MNT"/boot/efi/EFI/*/*.efi >/dev/null 2>&1 \
      || { BOOT_OK=0; warn "MISSING UEFI bootloader under /boot/efi/EFI"; }
  fi
  if [[ "$UNENCRYPTED_EXCEPTION" == "1" ]]; then
    mkdir -p "$TARGET_MNT/etc/thinclient"; echo "encrypted=0 exception=1" >"$TARGET_MNT/etc/thinclient/install-generation"
  fi
fi
# Keep the log ON the installed system so a failure can be diagnosed after reboot.
mkdir -p "$TARGET_MNT/var/log/thinclient" 2>/dev/null || true
cp -f "$CHROOT_LOG" "$TARGET_MNT/var/log/thinclient/install-chroot.log" 2>/dev/null || true
rm -f "$CHROOT_LOG"

if [[ "$BOOT_OK" -eq 0 ]]; then
  echo
  echo "  INSTALLATION FAILED — this disk would NOT boot."
  echo
  echo "  The system was copied, but the bootloader did not install, so the machine"
  echo "  would only start while the USB stick is plugged in."
  echo
  echo "  The bootloader log is at /var/log/thinclient/install-chroot.log on the"
  echo "  target disk. Please send that, or re-run 'sudo thinclient-install'."
  echo
  exit 1
fi
ok "Bootloader verified — this disk will boot on its own"

# --------------------------------------------------------------------------- #
# 5b. Auto-enrol: if an activation file is on the boot USB (or any mounted USB),
#     bake it into the installed licence config so the machine self-registers on
#     first boot — no manual step per device.
# --------------------------------------------------------------------------- #
# `|| true`: find exits non-zero when ANY of these paths is missing (often /run/media),
# and under set -e + pipefail that ended the whole install right after the bootloader.
ACT="$(find /run/live/medium /media /run/media /mnt -maxdepth 4 -name thinclient-activate.conf -type f 2>/dev/null | head -1 || true)"
if [[ -n "$ACT" ]]; then
  log "Baking activation config from ${ACT}"
  TCONF="$TARGET_MNT/etc/thinclient/license.conf"
  touch "$TCONF"
  for k in CONTROL_URL TENANT_TOKEN ENROLL_CODE DEVICE_SECRET LICENSE_ENFORCE; do
    v="$(sed -n "s/^${k}=//p" "$ACT" | head -1 | tr -d '\r')"
    [[ -n "$v" ]] || continue
    if grep -q "^${k}=" "$TCONF"; then sed -i "s#^${k}=.*#${k}=${v}#" "$TCONF"; else echo "${k}=${v}" >>"$TCONF"; fi
  done
fi

# --------------------------------------------------------------------------- #
# 5c. (Device name is now set at §3c, before the chroot, so it survives a failure
#      in the later stages. Nothing to do here.)
# --------------------------------------------------------------------------- #

# --------------------------------------------------------------------------- #
# 5d. Verify activation actually landed — loudly.
#
#     An installed-but-unactivated machine is the worst outcome: it boots, it
#     looks fine, and it never appears in the manager. That failure used to be
#     silent. Now the installer says so, in terms the operator can act on.
# --------------------------------------------------------------------------- #
TCONF="$TARGET_MNT/etc/thinclient/license.conf"
HAVE_CODE="$(sed -n 's/^ENROLL_CODE=//p'   "$TCONF" 2>/dev/null | head -1 | tr -d '\r')"
HAVE_SEC="$(sed -n 's/^DEVICE_SECRET=//p' "$TCONF" 2>/dev/null | head -1 | tr -d '\r')"
HAVE_TOK="$(sed -n 's/^TENANT_TOKEN=//p'  "$TCONF" 2>/dev/null | head -1 | tr -d '\r')"
# It holds the device secret: root only on the installed system (the agent keeps it so).
chmod 0600 "$TCONF" 2>/dev/null || true

if [[ -n "$HAVE_CODE" && -n "$HAVE_SEC" ]]; then
  ok "Activation verified — this device will appear in the manager on first boot"
elif [[ -n "$HAVE_TOK" ]]; then
  warn "This machine is INSTALLED but NOT ACTIVATED."
  warn "It will boot and work, but it will show as offline in the manager because it"
  warn "has no device credentials. Ask your administrator to approve it and run"
  warn "'sudo thinclient-install' again, or activate it from a USB stick."
else
  warn "No fleet configuration in this image — the device will not join a fleet."
fi

# --------------------------------------------------------------------------- #
# 6. Cleanup.
# --------------------------------------------------------------------------- #
log "Unmounting"
for fs in run sys proc dev/pts dev; do umount -R -l "$TARGET_MNT/$fs" 2>/dev/null || true; done
umount -R "$TARGET_MNT" 2>/dev/null || true
[[ "$ENCRYPT" == "1" ]] && { cryptsetup close "$MAPPER" 2>/dev/null || true; }

log "Installation complete on ${DISK}."
printf '\n\033[1;32mInstall complete.\033[0m\n'
if [[ "$ENCRYPT" == "1" ]]; then cat <<MSG
  ENCRYPTED INSTALL — one step at the FIRST power-on, at this machine's screen:
    1. A blue "Verification failed: Security Violation" box appears -> press Enter.
    2. "Press any key to perform MOK management" -> press a key within 10 seconds.
    3. Enroll key from disk -> TCEFI -> THINCLIENT-ENROLL-ME.der -> Continue -> Yes -> Reboot.
  After that the machine starts by itself, every time. Nobody will ever be asked for a
  disk password: only this machine's TPM can open its disk.
MSG
fi
cat <<EOF
  * Remove the USB stick and reboot: sudo reboot
  * The machine now boots the ThinClient appliance from ${DISK}.
  * To deploy to the fleet, clone ${DISK} with Clonezilla — see
    /opt/thinclient/docs/CLONEZILLA.md
EOF
