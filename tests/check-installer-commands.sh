#!/usr/bin/env bash
# Static check: every command the installer invokes must be a defined function or a
# real binary. The installer runs under `set -e`, so calling an undefined helper is
# exit 127 and kills the install mid-flight — which is exactly how `ok: command not
# found` reached a customer's machine after the helper was borrowed from build.sh.
# Run this before building an ISO.
set -uo pipefail
S="${1:-installer/install-to-disk.sh}"
[[ -r "$S" ]] || { echo "cannot read $S" >&2; exit 2; }

defs=$(grep -oE '^[a-z_]+\(\)' "$S" | sed 's/()//' | sort -u)
builtins="if then else elif fi for while do done case esac local return exit export set shift read echo printf eval source declare unset trap in function true false break continue"
# Ignore heredoc bodies: they are data, not commands.
body=$(awk '
  /<<[-]?[A-Za-z_'"'"'"]+/ { match($0, /<<[-]?['"'"'"]?[A-Za-z_]+/); tag=substr($0,RSTART,RLENGTH);
                              gsub(/^<<[-]?['"'"'"]?/,"",tag); inhd=1; next }
  inhd && $0 ~ "^"tag"$" { inhd=0; next }
  !inhd { print }
' "$S")

missing=""
while read -r c; do
  [[ -n "$c" ]] || continue
  grep -qx "$c" <<<"$defs" && continue
  [[ " $builtins " == *" $c "* ]] && continue
  command -v "$c" >/dev/null 2>&1 && continue
  missing="$missing $c"
done < <(awk '{ sub(/^[[:space:]]+/,""); if ($1 ~ /^[a-z_][a-z0-9_-]*$/) print $1 }' <<<"$body" | sort -u)

if [[ -n "$missing" ]]; then
  echo "UNRESOLVED COMMANDS:$missing"
  echo "(binaries absent from THIS host are expected; an undefined FUNCTION is a bug)"
  exit 1
fi
echo "OK: every command in $S resolves to a function or a binary"
