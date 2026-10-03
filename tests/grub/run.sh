#!/usr/bin/env bash
# Memory hardening (security plan A3) against the REAL grub-mkconfig, starting from the
# exact /etc/default/grub the installer writes. Opt-in (needs Docker; amd64 emulation
# on an ARM Mac takes a few minutes):   bash tests/grub/run.sh
#
# What it can't cover: the container's / is an overlay, so grub-probe is answered as a
# single ext4 partition (inside.sh) — device detection is the one part of
# grub-mkconfig the hardening doesn't touch. Whether a given machine BOOTS with
# intel_iommu=on is still a per-hardware-model test.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"
docker build --platform linux/amd64 -q -t tc-grub-test "$HERE" >/dev/null
docker run --platform linux/amd64 --rm -v "$ROOT:/project:ro" tc-grub-test bash /project/tests/grub/inside.sh
