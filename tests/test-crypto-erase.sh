#!/bin/bash
# Remote wipe on an ENCRYPTED machine destroys the disk key (security plan M6), against
# a REAL LUKS2 volume. Needs a privileged Linux container with cryptsetup:
#   docker run --rm --privileged --platform linux/amd64 -v "$PWD:/p:ro" tc-uki-builder bash /p/tests/test-crypto-erase.sh
set -u
pass=0; fail=0
ok(){ if eval "$2"; then echo "  PASS $1"; pass=$((pass+1)); else echo "  FAIL $1"; fail=$((fail+1)); fi; }
T=$(mktemp -d); truncate -s 64M $T/disk.img
L=$(losetup --find --show $T/disk.img)
printf 'test-pass' | cryptsetup luksFormat --type luks2 --pbkdf pbkdf2 --batch-mode $L -
printf 'test-pass' | cryptsetup open $L tc-erase-test -
echo hello > $T/marker; dd if=$T/marker of=/dev/mapper/tc-erase-test bs=512 count=1 conv=notrunc 2>/dev/null
echo "encrypted=1" > $T/gen
export TC_INSTALL_GEN=$T/gen TC_LUKS_MAPPER=tc-erase-test
R=$(python3 - <<PY
import importlib.machinery, importlib.util
spec = importlib.util.spec_from_loader("a", importlib.machinery.SourceFileLoader("a", "/p/scripts/thinclient-agent"))
a = importlib.util.module_from_spec(spec); spec.loader.exec_module(a)
print(a._luks_device(), a._crypto_erase())
PY
)
ok "found the LUKS partition behind the mapper" "[ \"\${R%% *}\" = $L ]"
ok "crypto-erase reports success" "[ \"\${R##* }\" = True ]"
ok "the open volume still reads (running system keeps going until power-off)" \
   "dd if=/dev/mapper/tc-erase-test bs=512 count=1 2>/dev/null | grep -q hello"
cryptsetup close tc-erase-test
ok "no key slot left in the header" "! cryptsetup luksDump $L | grep -qE '^\s+[0-9]+: luks2'"
ok "the right passphrase no longer opens it" "! (printf 'test-pass' | cryptsetup open --test-passphrase $L - 2>/dev/null)"
echo "encrypted=0" > $T/gen
ok "a plain machine never runs luksErase" "[ \"\$(python3 -c \"
import importlib.machinery, importlib.util
spec = importlib.util.spec_from_loader('a', importlib.machinery.SourceFileLoader('a', '/p/scripts/thinclient-agent'))
a = importlib.util.module_from_spec(spec); spec.loader.exec_module(a); print(a._crypto_erase())\")\" = False ]"
losetup -d $L; rm -rf $T
echo; echo "  $pass passed, $fail failed"; [ $fail -eq 0 ]
