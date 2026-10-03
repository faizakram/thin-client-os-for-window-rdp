#!/bin/bash
# Run a virtual thin client.  Inside the rig container:
#   vm.sh start <name> [--iso X.iso] [--disk-size 16G] [--no-secureboot]
#   vm.sh shot  <name> <out.png>      screenshot of the screen
#   vm.sh keys  <name> <qemu sendkey args...>
#   vm.sh stop  <name>
# Each VM keeps its disk, its UEFI variables (Secure Boot state, MOK) and its OWN
# TPM under /work/<name>/ — so "move the disk to another machine" = boot the disk
# with a different name's TPM.
set -euo pipefail
cmd="$1"; name="$2"; shift 2
D="/work/$name"; mkdir -p "$D"
case "$cmd" in
start)
  iso=""; size="16G"; sb=1; tpm_of="$name"; disk="$D/disk.qcow2"
  while [ $# -gt 0 ]; do case "$1" in
    --iso) iso="$2"; shift 2;; --disk-size) size="$2"; shift 2;;
    --no-secureboot) sb=0; shift;; --tpm-of) tpm_of="$2"; shift 2;;
    --disk-of) disk="/work/$2/disk.qcow2"; shift 2;; *) echo "bad arg $1"; exit 2;; esac; done
  [ -f "$disk" ] || qemu-img create -q -f qcow2 "$disk" "$size"
  if [ $sb = 1 ]; then CODE=/usr/share/OVMF/OVMF_CODE_4M.secboot.fd; VARS0=/usr/share/OVMF/OVMF_VARS_4M.ms.fd
  else CODE=/usr/share/OVMF/OVMF_CODE_4M.fd; VARS0=/usr/share/OVMF/OVMF_VARS_4M.fd; fi
  [ -f "$D/vars-$sb.fd" ] || cp "$VARS0" "$D/vars-$sb.fd"
  T="/work/$tpm_of/tpm"; mkdir -p "$T"
  pgrep -f "swtpm.*$T/sock" >/dev/null || swtpm socket --tpm2 --tpmstate dir="$T" \
      --ctrl type=unixio,path="$T/sock" --flags startup-clear --daemon
  sleep 1
  qemu-system-x86_64 -name "$name" -machine q35,smm=on -m 3072 -smp 2 \
    -global driver=cfi.pflash01,property=secure,value=on \
    -drive if=pflash,format=raw,unit=0,file="$CODE",readonly=on \
    -drive if=pflash,format=raw,unit=1,file="$D/vars-$sb.fd" \
    -chardev socket,id=chrtpm,path="$T/sock" -tpmdev emulator,id=tpm0,chardev=chrtpm \
    -device tpm-tis,tpmdev=tpm0 \
    -drive file="$disk",if=virtio,format=qcow2 \
    ${iso:+-drive file="$iso",media=cdrom,readonly=on} \
    -boot menu=off -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
    -vga std -display none -monitor unix:"$D/mon",server,nowait \
    -serial file:"$D/serial.log" -daemonize -pidfile "$D/qemu.pid"
  echo "started $name (secure boot: $sb, tpm of: $tpm_of)";;
shot)
  out="$1"; echo "screendump $D/shot.ppm" | socat - unix-connect:"$D/mon" >/dev/null; sleep 1
  convert "$D/shot.ppm" "$out" && echo "$out";;
keys)
  for k in "$@"; do echo "sendkey $k" | socat - unix-connect:"$D/mon" >/dev/null; sleep 0.3; done;;
stop)
  [ -f "$D/qemu.pid" ] && kill "$(cat "$D/qemu.pid")" 2>/dev/null || true; rm -f "$D/qemu.pid"; echo stopped;;
esac
