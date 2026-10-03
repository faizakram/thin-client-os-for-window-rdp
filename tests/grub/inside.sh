#!/bin/bash
set -u
# A container's / is an overlay that grub-probe can't map to a disk — the ONE part of
# grub-mkconfig our change doesn't touch. Answer it like a single-ext4-partition box.
real=$(command -v grub-probe); mv "$real" "$real.real"
cat > "$real" <<'P'
#!/bin/sh
for a in "$@"; do case "$a" in --target=*) t="${a#--target=}";; -t) n=1;; *) [ -n "${n:-}" ] && { t="$a"; n=; };; esac; done
case "$t" in
  device) echo /dev/sda1;; fs) echo ext2;; fs_uuid) echo 0d3a7f4e-1111-4222-8333-944455556666;;
  partmap) echo msdos;; abstraction) echo;; drive) echo "(hd0,msdos1)";; bios_hints) echo "--hint-bios=hd0,msdos1";;
  efi_hints|baremetal_hints|arc_hints|ieee1275_hints) echo;; compatibility_hint) echo "hd0,msdos1";; *) echo;;
esac
P
chmod +x "$real"
mkdir -p /boot/grub; : > /boot/vmlinuz-6.12.48+deb13-amd64; : > /boot/initrd.img-6.12.48+deb13-amd64
# Exactly what install-to-disk.sh leaves on an installed device:
sed -n '/^if \[ ! -f \/etc\/default\/grub \]; then/,/^GRUB_DISABLE_OS_PROBER/p' /project/installer/install-to-disk.sh > /tmp/inst.sh
bash -c "$(sed -n '/^if \[ ! -f \/etc\/default\/grub \]/,/^fi/p' /tmp/inst.sh)"
sed -n '/^sed -i .s|^GRUB_CMDLINE_LINUX_DEFAULT/,/GRUB_DISABLE_OS_PROBER/p' /project/installer/install-to-disk.sh | grep -v "^#" | bash
grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null; echo "baseline grub.cfg rc=$? lines=$(wc -l < /boot/grub/grub.cfg)"
python3 /project/tests/grub/mem-harden-real-grub.py
