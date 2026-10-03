#!/bin/bash
# tc-boot-bless against a fake ESP + efivarfs (the real thing is proven in the VM rig).
# Linux only (run in any Debian container):  bash tests/test-boot-bless.sh
set -u
B="$(cd "$(dirname "$0")/.." && pwd)/tools/phaseb/tc-boot-bless"
T=$(mktemp -d); export TC_ESP=$T/esp TC_EFIVARS=$T/vars TC_KERNEL_DIR=$T/state TC_BLESS_SKIP_KIOSK_CHECK=1
mkdir -p $TC_ESP/EFI/Linux $TC_EFIVARS
V=$TC_EFIVARS/LoaderBootCountPath-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f
pass=0; fail=0
ok(){ if eval "$2"; then echo "  PASS $1"; pass=$((pass+1)); else echo "  FAIL $1"; fail=$((fail+1)); fi; }
setvar(){ { printf '\x07\x00\x00\x00'; printf '%s' "$1" | iconv -f utf-8 -t utf-16le; printf '\x00\x00'; } > "$V"; }

touch $TC_ESP/EFI/Linux/thinclient-6.12.111.efi
bash "$B"; ok "no counter variable (a good image started): nothing to do" "[ \$? -eq 0 ] && ls $TC_ESP/EFI/Linux | grep -qx thinclient-6.12.111.efi"

touch $TC_ESP/EFI/Linux/thinclient-6.12.120+1-1.efi
setvar '\EFI\Linux\thinclient-6.12.120+1-1.efi'
bash "$B"
ok "the started image is confirmed: counter dropped" "[ -f $TC_ESP/EFI/Linux/thinclient-6.12.120.efi ] && [ ! -f $TC_ESP/EFI/Linux/thinclient-6.12.120+1-1.efi ]"
ok "recorded for thinclient-kernel" "[ \"\$(cat $TC_KERNEL_DIR/blessed)\" = thinclient-6.12.120.efi ]"
ok "other images untouched" "[ -f $TC_ESP/EFI/Linux/thinclient-6.12.111.efi ]"

touch "$TC_ESP/EFI/Linux/thinclient-6.12.130+2.efi"; setvar '\EFI\Linux\thinclient-6.12.130+2.efi'
unset TC_BLESS_SKIP_KIOSK_CHECK
bash "$B"; rc=$?
ok "kiosk not running: NOT confirmed (exit 1, retried later)" "[ $rc -eq 1 ] && [ -f '$TC_ESP/EFI/Linux/thinclient-6.12.130+2.efi' ]"
export TC_BLESS_SKIP_KIOSK_CHECK=1
setvar '\EFI\BOOT\BOOTX64.EFI'
bash "$B"; ok "a path outside EFI/Linux/thinclient-* is never renamed" "[ \$? -eq 0 ] && [ -f '$TC_ESP/EFI/Linux/thinclient-6.12.130+2.efi' ]"
setvar '\EFI\Linux\thinclient-6.12.140+1-1.efi'
bash "$B"; ok "a counter naming a missing file: nothing happens" "[ \$? -eq 0 ]"
echo; echo "  $pass passed, $fail failed"; [ $fail -eq 0 ]
