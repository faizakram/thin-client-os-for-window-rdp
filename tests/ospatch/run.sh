#!/usr/bin/env bash
# OS security updates (security plan G2) against the REAL security.debian.org, in a
# container built like an old device: packages from the main archive only, so there
# are real security fixes pending. Opt-in (needs Docker + internet):
#   bash tests/ospatch/run.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"
docker build --platform linux/amd64 -q -t tc-ospatch-test "$HERE" >/dev/null
docker run --platform linux/amd64 --rm -v "$ROOT:/project:ro" tc-ospatch-test bash /project/tests/ospatch/inside.sh
