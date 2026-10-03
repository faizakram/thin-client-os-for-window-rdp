#!/bin/bash
# Phase B M4 — run inside the tc-rig container. Each attack boots the encrypted test disk
# (/work/encA, sealed to /work/encA/tpm) with ONE thing changed; the disk must stay locked.
#   atk1  disk moved to another PC that trusts our (public) certificate: own, fresh TPM
#   atk2  Secure Boot switched OFF, same TPM
#   atk3  boot image tampered (1 byte), Secure Boot on, same TPM
#   atk4  boot image signed with our key but a PCR policy NOT signed by our policy key
set -u
V=/project/tests/vm/vm.sh
run(){ name=$1; shift
  rm -f /work/$name/serial.log; bash $V start $name "$@" >/dev/null; sleep 420
  bash $V shot $name /project/tests/vm/$name.png >/dev/null
  L=$(sed "s/\x1b\[[0-9;:]*m//g" /work/$name/serial.log 2>/dev/null)
  if grep -aq "Switching root" <<<"$L"; then verdict="DISK OPENED  <-- ATTACK SUCCEEDED (BAD)"
  elif grep -aq "Failed to start systemd-cryptsetup" <<<"$L"; then verdict="locked: TPM refused the key"
  elif [ -z "$L" ]; then verdict="locked: never reached our kernel (see screenshot)"
  else verdict="locked: no unlock seen"; fi
  echo "$name: $verdict"
  bash $V stop $name >/dev/null; }
run atk1
run atk2 --no-secureboot --tpm-of encA
run atk3 --tpm-of encA
run atk4 --tpm-of encA
