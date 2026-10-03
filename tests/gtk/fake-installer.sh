#!/bin/bash
# Stand-in for thinclient-install --ui: speaks the same "@@TC" protocol so the wizard can
# be driven on screen without a disk. FAKE_MODE: ok | badmachine | fail
echo "noise before the checks"
if [[ " $* " == *" --preflight "* ]]; then
  echo "@@TC check image encrypted"; echo "@@TC check uefi ok"
  if [[ "${FAKE_MODE:-ok}" == badmachine ]]; then echo "@@TC check secureboot fail"; else echo "@@TC check secureboot ok"; fi
  echo "@@TC check tpm ok"; echo "@@TC preflight-done"; exit 0
fi
echo "args: $*" >> "${FAKE_LOG:-/tmp/fake-installer.args}"
echo "@@TC stage approval"
echo "@@TC pairing K7Q-4MX"; echo "@@TC waiting 0"; sleep 0.5
echo "@@TC approved"
for attempt in 1 2; do
  echo "@@TC need-otp $attempt 5"
  read -r otp || { echo "@@TC failed cancelled"; exit 1; }
  echo "otp received: ${#otp} chars" >> "${FAKE_LOG:-/tmp/fake-installer.args}"
  [[ "$otp" == "123456" ]] && break
  echo "@@TC otp-error That password is not right. Try again (attempt $attempt of 5)."
done
[[ "${FAKE_MODE:-ok}" == fail ]] && { echo "@@TC stage partition"; echo "@@TC failed Could not write the partition table."; exit 1; }
for s in partition encrypt seal; do echo "@@TC stage $s"; echo "working on $s"; sleep 0.3; done
echo "@@TC stage copy"
for p in 5 40 77 100; do printf '  1,234,567  %d%%   12.3MB/s    0:00:01 (xfr#1, to-chk=0/9)\r' $p; sleep 0.3; done; echo
for s in configure boot; do echo "@@TC stage $s"; sleep 0.3; done
echo "@@TC done encrypted=1"
echo "@@TC await-reboot"
IFS= read -r answer || answer=""
echo "restart answer: $answer" >> "${FAKE_LOG:-/tmp/fake-installer.args}"
exit 0
