#!/usr/bin/env bash
# =============================================================================
#  ThinClient OS — Offline admin-password hash generator (build-time helper)
#
#  Generates a SHA-512 crypt hash for the admin password so you can bake a
#  non-default password into the image BEFORE building, without ever storing
#  the plaintext. Prints a ready-to-paste ADMIN_PASSWORD_HASH=... line.
#
#  Usage:
#     ./scripts/gen-admin-hash.sh                 # prompts (hidden input)
#     TC_ADMIN_PASSWORD='s3cret' ./scripts/gen-admin-hash.sh   # non-interactive
# =============================================================================
set -euo pipefail

if ! command -v openssl >/dev/null 2>&1; then
  echo "openssl is required." >&2; exit 1
fi

pw="${TC_ADMIN_PASSWORD:-}"
if [[ -z "$pw" ]]; then
  read -r -s -p "Admin password: " pw; echo >&2
  read -r -s -p "Confirm:        " pw2; echo >&2
  [[ "$pw" == "$pw2" ]] || { echo "Passwords do not match." >&2; exit 1; }
fi
[[ -n "$pw" ]] || { echo "Password cannot be empty." >&2; exit 1; }

salt="$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n' | cut -c1-12)"
hash="$(printf '%s' "$pw" | openssl passwd -6 -salt "$salt" -stdin)"
echo "ADMIN_PASSWORD_HASH=${hash}"
