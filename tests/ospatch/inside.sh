#!/bin/bash
# Runs INSIDE the stale-trixie container (see run.sh). Real security.debian.org.
set -u
P=/project/scripts/thinclient-ospatch
export TC_OSPATCH_NOREBOOT=1
D=/var/lib/thinclient/os-update
pass=0; fail=0
ok(){ if eval "$2"; then echo "  PASS $1"; pass=$((pass+1)); else echo "  FAIL $1"; fail=$((fail+1)); fi; }
ver(){ dpkg-query -W -f='${Version}' "$1" 2>/dev/null; }
res(){ python3 -c "import json; print(json.load(open('$D/result.json')).get('$1'))"; }

echo "== check / download install nothing; the device's own apt state is untouched"
python3 $P check >/tmp/c.json
ok "real security updates found" "[ \$(python3 -c 'import json; print(len(json.load(open(\"/tmp/c.json\"))[\"pending\"]))') -gt 0 ]"
ok "no apt error" "[ \"\$(python3 -c 'import json; print(json.load(open(\"/tmp/c.json\"))[\"error\"])')\" = None ]"
ok "device's own apt lists untouched" "[ -z \"\$(ls /var/lib/apt/lists 2>/dev/null | grep -v -e lock -e partial -e auxfiles)\" ]"
OPENSSL_BEFORE=$(ver openssl)
python3 $P download >/dev/null
ok "download installs nothing" "[ \"\$(ver openssl)\" = \"$OPENSSL_BEFORE\" ]"
PENDING=$(python3 -c "import json; print(' '.join(json.load(open('$D/state.json'))['pending']))")

echo "== bad input is refused"
python3 $P stage "openssl=1.0; rm -rf /" "../etc=1" >/dev/null
ok "malformed specs never staged" "[ ! -f $D/stage.json ]"

echo "== a staged package that was never downloaded: apply fails cleanly, nothing changes"
python3 $P stage "openssl=99.9-fake" >/dev/null
python3 $P apply 2>/dev/null
ok "reported as failed" "[ \"\$(res result)\" = failed ]"
ok "openssl untouched" "[ \"\$(ver openssl)\" = \"$OPENSSL_BEFORE\" ]"
ok "stage cleared (not retried at every boot)" "[ ! -f $D/stage.json ]"

echo "== fleet device: only the APPROVED subset is installed"
SUB=$(printf '%s\n' $PENDING | grep -E '^(libssl3t64|openssl|openssl-provider-legacy)=' | tr '\n' ' ')
OTHER=$(printf '%s\n' $PENDING | grep -vE '^(libssl3t64|openssl|openssl-provider-legacy)=' | head -1)
echo "# THINCLIENT-LOCAL-EDIT" >> /etc/ssl/openssl.cnf
python3 $P stage $SUB >/dev/null; python3 $P apply 2>/dev/null
ok "subset installed ok" "[ \"\$(res result)\" = ok ]"
for s in $SUB; do ok "  $s" "[ \"\$(ver ${s%%=*})\" = \"${s#*=}\" ]"; done
[ -n "$OTHER" ] && ok "a NOT-approved update stays uninstalled (${OTHER%%=*})" "[ \"\$(ver ${OTHER%%=*})\" != \"${OTHER#*=}\" ]"
ok "our config file kept (--force-confold)" "grep -q THINCLIENT-LOCAL-EDIT /etc/ssl/openssl.cnf"
ok "FreeRDP still runs" "xfreerdp3 --version >/dev/null 2>&1"

echo "== power cut mid-install: repaired at the next boot"
if [ -n "$OTHER" ]; then
  DEB=$(ls /var/cache/apt/archives/${OTHER%%=*}_*.deb 2>/dev/null | head -1)
  dpkg --unpack "$DEB" >/dev/null 2>&1          # unpacked, never configured = an interrupted install
  ok "dpkg reports the interrupted install" "[ -n \"\$(dpkg --audit)\" ]"
  python3 $P apply 2>/dev/null
  ok "apply finished it (dpkg --configure -a)" "[ -z \"\$(dpkg --audit)\" ]"
  ok "recorded as a repair" "[ \"\$(res repaired)\" = True ]"
fi

echo "== the mirror is unreachable (a customer LAN blocking it): reported, nothing changed"
TC_OSPATCH_MIRROR=http://127.0.0.1:9/debian-security python3 $P check >/tmp/e.json 2>/dev/null
ok "error reported" "[ \"\$(python3 -c 'import json; print(bool(json.load(open(\"/tmp/e.json\"))[\"error\"]))')\" = True ]"
ok "FreeRDP still runs" "xfreerdp3 --version >/dev/null 2>&1"

echo "== nothing staged: apply is a no-op"
python3 $P apply; ok "rc 0" "[ \$? -eq 0 ]"

echo; echo "  $pass passed, $fail failed"; [ $fail -eq 0 ]
