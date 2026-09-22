#!/usr/bin/env bash
# Every GTK CSS blob that gets .encode("ascii") must contain ONLY ASCII.
# A single typographic dash in a CSS comment raises UnicodeEncodeError at import
# and the GUI app dies before drawing anything — which is how the chat panel
# silently disappeared from a customer's device.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
fail=0
for f in scripts/thinclient-chat scripts/thinclient-connect scripts/thinclient-lock scripts/thinclient-netbadge; do
  [[ -r "$f" ]] || continue
  python3 - "$f" <<'PY' || fail=1
import sys, re
p = sys.argv[1]
src = open(p, encoding="utf-8").read()
bad = []
# every triple-quoted string that is followed (within ~200 chars) by .encode("ascii")
for m in re.finditer(r'"""(.*?)"""', src, re.S):
    tail = src[m.end():m.end() + 200]
    if '.encode("ascii")' in tail or ".encode('ascii')" in tail:
        for ch in set(m.group(1)):
            if ord(ch) > 127:
                bad.append(hex(ord(ch)) + " " + repr(ch))
if bad:
    print("  FAIL %s: non-ASCII in an ascii-encoded string: %s" % (p, sorted(set(bad))))
    sys.exit(1)
print("  OK   %s" % p)
PY
done
exit $fail
