#!/usr/bin/env bash
# =============================================================================
#  Unit tests — releasing the target disk before partitioning it.
#
#  A real install died here with:
#
#      wipefs: error: /dev/sda: probing initialization failed: Device or resource busy
#
#  The installer only ever unmounted its OWN mount point, never the disk it was about to
#  erase. A live boot routinely holds that disk: the desktop auto-mounts its partitions,
#  a swap partition is activated, or an LVM group / RAID array on it is assembled at
#  boot. Each keeps the whole block device open and each needs a different command.
#
#  What must hold, and why each one matters:
#   * swap on the TARGET disk is released FIRST — umount cannot touch it, so doing it
#     last leaves the disk busy after everything else has let go;
#   * swap on ANY OTHER disk is left alone — that is usually the live USB being booted;
#   * nested mounts unwind deepest-first;
#   * a disk that stays busy NEVER reaches partitioning, and the failure names what is
#     holding it instead of repeating a wipefs error nobody can act on.
#
#  The block is extracted from installer/install-to-disk.sh, so the real script is under
#  test rather than a copy that can drift.
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
export CURRENT_SUITE="installer-disk-release"
source "$HERE/test-helpers.sh"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
printf 'Filename\tType\tSize\tUsed\tPriority\n/dev/sda3\tpartition\t2097148\t0\t-2\n/dev/sdb1\tpartition\t100\t0\t-3\n' \
  > "$WORK/swaps"
# Swap exists, but none of it on the target disk — needed for the "nothing is holding it"
# case, which otherwise finds the sda3 swap above and correctly reports THAT instead.
printf 'Filename\tType\tSize\tUsed\tPriority\n/dev/sdb1\tpartition\t100\t0\t-3\n' \
  > "$WORK/swaps-clean"

python3 - "$ROOT/installer/install-to-disk.sh" "$WORK/sec.sh" <<'PY'
import io, sys
src, out = sys.argv[1], sys.argv[2]
t = io.open(src, encoding="utf-8").read()
sec = t[t.index('# Release the target disk before touching it.'):t.index('sgdisk --zap-all "$DISK"')]
io.open(out, "w").write('''#!/usr/bin/env bash
set -uo pipefail
DISK=/dev/sda; TARGET_MNT=/mnt/target; EFI_PART=/dev/sda1; ROOT_PART=/dev/sda2
log(){ printf '[install] %s\\n' "$*"; }
ORDER=""
swapoff(){ ORDER="$ORDER swapoff:$1"; }
umount(){ ORDER="$ORDER umount:${!#}"; }
vgchange(){ ORDER="$ORDER vgchange"; }
mdadm(){ ORDER="$ORDER mdadm"; }
dmsetup(){ ORDER="$ORDER dmsetup"; }
udevadm(){ :; }
command(){ case "$2" in vgchange|mdadm|dmsetup) return 0;; *) builtin command "$@";; esac; }
lsblk(){ printf '%s\\n' "$LSBLK_OUT"; }
WIPE_N=0
wipefs(){ WIPE_N=$((WIPE_N+1)); [ "$WIPE_N" -ge "${WIPE_OK_ON:-1}" ] && return 0 || return 1; }
sleep(){ :; }
''' + sec + '''
echo "ORDER:$ORDER"
echo "REACHED_PARTITIONING wipefs_calls=$WIPE_N"
''')
PY

run() {   # run <lsblk-mountpoints> <wipefs-succeeds-on-attempt> [swaps-fixture]
  OUT="$(LSBLK_OUT="$1" WIPE_OK_ON="$2" TC_SWAPS_FILE="$WORK/${3:-swaps}" bash "$WORK/sec.sh" 2>&1)"; RC=$?
  ORDER="$(sed -n 's/^ORDER://p' <<<"$OUT")"
}

echo "== the disk is released in an order that actually works =="
run "/mnt/old
/mnt/old/boot" 1
assert_eq "0" "$RC" "a disk that frees up is partitioned"
assert_contains "$OUT" "REACHED_PARTITIONING" "and reaches partitioning"
assert_contains "$ORDER" "swapoff:/dev/sda3" "swap on the target disk is released"
assert_not_contains "$ORDER" "swapoff:/dev/sdb1" "swap on another disk is NOT touched (that is the live USB)"
# Ordering: swapoff must precede the partition unmounts, or the disk stays busy.
SWAP_AT="${ORDER%%swapoff:*}"
assert_not_contains "$SWAP_AT" "umount:/mnt/old" "swap is released BEFORE the partitions are unmounted"
# Nested mounts, deepest first.
DEEP="${ORDER%%umount:/mnt/old /*}"
assert_contains "$ORDER" "umount:/mnt/old/boot umount:/mnt/old" "nested mounts unwind deepest-first"
assert_contains "$ORDER" "vgchange" "LVM groups are deactivated"
assert_contains "$ORDER" "mdadm" "RAID arrays are stopped"

echo
echo "== a disk grabbed back by udev is retried, not abandoned =="
run "" 2
assert_eq "0" "$RC" "a second attempt after settling succeeds"
assert_contains "$OUT" "wipefs_calls=2" "and it took exactly two attempts"

echo
echo "== a disk that stays busy is never partitioned =="
run "/dev/sda1 /media/usb0" 99
assert_eq "1" "$RC" "the installer stops"
assert_not_contains "$OUT" "REACHED_PARTITIONING" "the disk is never partitioned"
assert_contains "$OUT" "has NOT been changed" "the operator is told the disk is untouched"

echo
echo "== and it says WHAT is holding the disk =="
run "/dev/sda1 /media/usb0
/dev/sda2 /mnt/old" 99
assert_contains "$OUT" "Still in use by" "the holders are listed"
assert_contains "$OUT" "/media/usb0" "naming the mount point, not just a wipefs error"
assert_contains "$OUT" "is in use as swap" "and the swap partition"

echo
echo "== nothing obvious holding it is a different message =="
# No mounts AND no swap on this disk: the installer has nothing to name, which points at
# the disk itself rather than at something to unmount.
run "" 99 swaps-clean
assert_contains "$OUT" "failing" "a disk with no visible holder suggests hardware, not mounts"

finish_suite
