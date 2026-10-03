#!/bin/bash
# Edit the boot partition (unencrypted FAT) of a rig VM's disk, from a privileged container:
#   esp.sh <vm> ls                       list EFI/Linux and loader/
#   esp.sh <vm> put <local-file> <ESP-path>
#   esp.sh <vm> cat <ESP-path>
set -euo pipefail
VM="$1"; shift; Q="/work/$VM/disk.qcow2"
command -v mcopy >/dev/null || (apt-get update -qq && apt-get install -y -qq mtools qemu-utils >/dev/null 2>&1)
RAW=/tmp/esp-$VM.raw
qemu-img convert -O raw "$Q" "$RAW"
export MTOOLS_SKIP_CHECK=1; IMG="$RAW@@1048576"
case "$1" in
  ls)  mdir -b -i "$IMG" ::/EFI/Linux 2>/dev/null; mdir -b -i "$IMG" ::/loader 2>/dev/null || true ;;
  put) mcopy -o -i "$IMG" "$2" "::$3"; qemu-img convert -O qcow2 "$RAW" "$Q"; echo "put $3" ;;
  cat) mtype -i "$IMG" "::$2" ;;
esac
rm -f "$RAW"
