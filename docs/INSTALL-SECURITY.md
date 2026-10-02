# ThinClient OS — Installation Architecture & Security Review

**Reviewed:** 8 September 2026 · against the deployed manager, OTA 1.0.105 and `iso/thinclient.iso`
(volume `THINCLIENT 1.0.105`, sha256 `5eab367cdc174c89de0ee47e0dbf683a316daec43b487646969fd02c6d6c05b3`)

**Question this answers:** can someone who obtains the ISO, or a pen drive, join the fleet
without permission?

**Short answer:** the enrolment path is now closed behind human approval and verified by test.
Three gaps remain that are *not* about enrolment — a shared admin password baked into the ISO,
device secrets readable by the kiosk operator, and one pen-drive route that dead-ends silently.
None of them are enforced today because the gate is still switched off.

---

## 1. Where the risk actually was

The tenant enrolment token is baked into the ISO (or handed over on a pen drive). Until this
change, `POST /api/devices/register` turned that token straight into an **ACTIVE device**,
unattended:

```
copied ISO ──► tenant token ──► /api/devices/register ──► ACTIVE device, no human involved
```

Because the token lives on media you hand to customers, and because anyone who boots the ISO has
local root, the token must be treated as **semi-public**. It can never be the thing that grants
access. That is the principle the new design is built on.

---

## 2. The installation flow

Two codes travel in **opposite directions**, and they defend different things:

| Code | Direction | What it proves |
|---|---|---|
| **Pairing code** (`XVN-AKP`) | manager → device screen → spoken to approver | *which machine* is asking. Without it, two simultaneous installs are indistinguishable and the approver can hand a seat to the wrong one. |
| **One-time password** (`CAEM-3LRW`) | manager → approver → spoken to operator | *a human at that machine* is talking to an authorised admin. |

```
      MACHINE BEING INSTALLED              MANAGER                     APPROVER
      (live ISO, operator present)   (your manager URL)        (tenant admin / super admin)
                 │                            │                            │
   1  request ── │ ─ tenant token + hwid ───► │                            │
                 │                            │                            │
   2             │ ◄── pairing code ONLY ──── │   creates PENDING request   │
                 │     (no credentials)       │                            │
                 │                            │                            │
   3  shows "XVN-AKP" on screen               │                            │
                 │                            │                            │
   4             │ ══ operator reads the code aloud (phone, not network) ══► │
                 │                            │                            │
   5             │                            │ ◄── confirms it matches,  ──│
                 │                            │     approves               │
                 │                            │                            │
   6             │                            │ ─── one-time password ────► │
                 │                            │  (only its hash is stored)  │
                 │                            │                            │
   7             │ ◄═══ approver reads the password to the operator ═══════ │
                 │                            │                            │
   8  claim ──── │ ─ request + hwid + password ──► verifies:                │
                 │                            │   • status is APPROVED      │
                 │                            │   • hwid matches            │
                 │                            │   • hash matches, not expired
                 │                            │   • attempts < 5            │
                 │                            │   • single-use, in a txn    │
                 │                            │                            │
   9             │ ◄══ enrolment code + device secret ══ (ONCE, this hwid)  │
                 │                            │                            │
              install completes          device CLAIMED               audited
```

Steps 1–8 hand out **nothing an attacker can use**. If approval never comes, the installer stops
and the disk is left unactivated.

**Password properties:** 8 characters from a 30-symbol alphabet (no `O 0 I 1 S 5`, so it survives
being read down a phone line) ≈ 6.6 × 10¹¹ combinations · 15-minute expiry · 5 attempts then the
request burns · single use · bound to one hardware id · stored only as a bcrypt hash, wiped after
use.

### Why the installer, and not the agent

The agent runs headless — nobody is there to type a password. The installer runs from the live
ISO, where a person is already sitting. So enrolment happens during installation, and the agent
simply finds credentials already present on first boot.

### Why the machine-id is now generated at install time

`hwid = sha256(/etc/machine-id)[:32]`. The installer used to **blank** the machine-id and let
first boot generate it — which meant the final hardware id did not exist yet, so there was
nothing for an approval to bind to. The installer now generates the identity itself
(`install-to-disk.sh` §3b), and `thinclient-firstboot` still regenerates it if the hardware
fingerprint later changes, which correctly forces re-approval on cloned hardware.

---

## 3. The three pen-drive routes

This is the part worth being precise about, because they behave differently.

```
  A. pen drive present DURING installation  (activation file has TENANT_TOKEN)
     ├─ installer §5b bakes CONTROL_URL + TENANT_TOKEN into the target
     ├─ installer §5d runs the approval flow above
     └─ ✅ correctly gated — this is the intended path

  B. pen drive added AFTER installation     (activation file has TENANT_TOKEN)
     ├─ thinclient-provision (boot + udev) writes TENANT_TOKEN into license.conf
     ├─ headless agent calls /api/devices/register
     ├─ a gated tenant returns 403 — and there is no terminal to type a password into
     └─ ❌ the machine silently never enrols   ← GAP 2

  C. pen drive carries ENROLL_CODE + DEVICE_SECRET  (created in the console)
     ├─ thinclient-provision imports them directly; no registration call is needed
     └─ ✅ bypasses approval BY DESIGN — an admin already authorised it explicitly
        when they created the device under Tenant → Enrol device
```

**Route C is the workaround for route B.** For a gated tenant, either install with the pen drive
present (A), or put per-device credentials on the pen drive (C) instead of a bare tenant token.

---

## 4. Attacks the gate closes

Each was checked against the running system — 27 server-side assertions plus a scripted run of
the real installer against production.

| If an attacker… | What stops it | Result |
|---|---|---|
| Copies the ISO and boots it on their own hardware | A gated tenant refuses `/api/devices/register` | `403` |
| Asks via the new endpoint and waits | The request endpoint can only ever return a pairing code | no creds |
| Guesses the one-time password | 6.6 × 10¹¹ space, 5 attempts, then the request burns | infeasible |
| Intercepts a password meant for another machine | The approval is bound to the requesting hardware id | `404` |
| Replays a password that already worked | Single-use inside one transaction; hash then wiped | `409` |
| Reads the database looking for passwords | Only a bcrypt hash is stored, deleted after use | nothing |
| Races a legitimate install to be approved instead | The pairing code on the real machine's screen won't match | visible |
| Floods the approval queue to force a mistake | 25 pending per tenant, plus per-IP limits | `429` |
| Steals `license.conf` and uses it on another machine | Every agent call checks the bound hardware id | `403` |
| Clones an approved disk onto different hardware | Board serial + onboard NIC MACs change → machine-id regenerated → secret no longer matches its hwid | `403` |
| Approves a machine belonging to another tenant | Every approval path is tenant-scoped | `404` |
| Sends hostile machine details to attack the console | Reduced to 12 flat scalars, 120 chars each, before storage | bounded |

---

## 5. Gaps still open

Ordered by what I would fix first.

### 1 — CRITICAL · The gate is switched off on every tenant

`requireInstallApproval = false` for QUANTUM, Acme and Demo, so **none of section 4 is enforced
right now.** This is deliberate: gating a tenant before its ISO and firmware can participate
would block installs rather than protect them.

*Fix:* flash the new ISO, then flip the toggle per tenant. Order in section 6.

### 2 — HIGH · Pen drive added after installation dead-ends silently

Route B above. Introduced by closing the register path. The machine appears to activate — the
token is written, the agent restarts — but a gated tenant refuses the registration and the
operator sees nothing.

*Fix:* add a first-boot enrolment prompt on the device's own screen (it already has a GUI, a
keyboard and `thinclient-enroll`), so route B becomes interactive like route A. Until then, use
route C for gated tenants and say so in the runbook.

### 3 — HIGH · One admin password for every device built from an ISO

`/etc/thinclient/admin.conf` ships **inside the ISO** carrying `ADMIN_PASSWORD_HASH` (`$6$`,
SHA-512 crypt). Two consequences:

- Anyone who can mount the ISO can extract the hash and attack it offline. No root needed.
- The password is the same on **every device built from that image**, so it cannot be revoked for
  one site, and a technician who leaves keeps working keys to the whole fleet.

Admin Mode gates it well otherwise — 5 attempts, then lockout, and the password is never stored
in plaintext.

*Fix:* rotate it per device. The manager already pushes a per-device screen-lock password
(`Device.pendingLockPassword`, consumed on the next poll) — the same mechanism fits the admin
password exactly. Failing that, generate a long random password per ISO build and treat the image
itself as a secret.

### 4 — HIGH · Device secret and tenant token are readable by the kiosk operator

`license.conf` is mode **0644**, and `thinclient-provision` explicitly re-applies `chmod 0644`
after writing to it. It holds `TENANT_TOKEN`, `DEVICE_SECRET` and `ENROLL_CODE`.

So any local user — including the kiosk operator on a normal shop-floor device — can read the
tenant token for the whole tenant. The device secret matters less, because hardware-id binding
means it only works on the machine it is already on.

This is **not** sloppiness: `thinclient-connect` runs as the kiosk user and reads that file. But
it only reads **one** key from it: `LICENSE_ENFORCE`.

*Fix:* split the file. Non-secrets (`CONTROL_URL`, `LICENSE_ENFORCE`, `DEVICE_NAME`) stay at 0644
where `thinclient-connect` can read them; secrets (`TENANT_TOKEN`, `DEVICE_SECRET`,
`ENROLL_CODE`, `RDP_PASSWORD_ENC`) move to a root-only 0600 file read by the agent, the installer
and provision — all of which already run as root. Touches `thinclient-agent`,
`thinclient-provision`, `thinclient-firstboot`, `thinclient-enroll` and `install-to-disk.sh`.

### 5 — MEDIUM · The pairing code proves which machine, not who is calling

Someone holding the tenant token can raise a real request and phone the tenant admin claiming to
be the technician on site: *"approve code XVN-AKP for me."* Every technical control behaves
correctly; the human is the remaining path.

*Fix:* make the approver **type** the pairing code rather than click Approve. That forces them to
read it off the machine physically in front of them, and an attacker reciting it down a phone no
longer suffices. Cheap, and it converts a social problem into a physical-presence check.

### 6 — MEDIUM · One approval can still become many devices

The anti-clone chain depends on `thinclient-firstboot` noticing the hardware changed. Someone
with root on a legitimately approved machine can disable that service, then clone the disk to
many machines sharing one identity and one licensed seat. The manager sees a single device.

*Fix:* detect duplicates server-side — one device reporting from two addresses, or overlapping
sessions, is not physically possible. Longer term, bind identity to the TPM rather than to
`/etc/machine-id`.

### 7 — MEDIUM · The kiosk user's sudo rules allow a plausible route to root

`config/sudoers-thinclient` grants the kiosk user, with no password:

```
/usr/bin/apt-get update
/usr/bin/apt-get -y upgrade
/usr/bin/nmcli *
/opt/thinclient/bin/thinclient-install, /opt/thinclient/bin/thinclient-install *
```

`nmcli *` lets the operator repoint DNS; `apt-get -y upgrade` then runs maintainer scripts as
root. Package signature checking is what stands between that and full root, so this is a chain
rather than a one-step escape — but it is a wide grant for a kiosk. `thinclient-install *` also
lets the operator wipe any disk in the machine.

*Fix:* replace the `apt-get` grants with a specific root-owned wrapper script (updates already go
through `thinclient-update-apply.service`), narrow `nmcli *` to the subcommands the Wi-Fi picker
actually needs, and drop the trailing `*` from `thinclient-install`.

### 8 — LOW · No way to rotate a leaked tenant token

The design assumes the token is semi-public, which is right, but if you learn one has leaked
there is no control in the console to replace it.

*Fix:* a "rotate enrolment token" button on the tenant page. Existing devices authenticate with
their own per-device secret, so rotation only affects future installs.

### 9 — LOW · The admin API token can approve installs by itself

Approval accepts either an admin session or the `ADMIN_API_TOKEN` bearer (convenient for
automation, and how this was tested). If that token leaks, an attacker can approve their own
request without involving a human.

*Fix:* exclude approval from bearer auth so it always needs a real session, or keep the token
strictly server-side and rotate on suspicion. Approvals are audited with the actor either way.

### 10 — LOW · Rate limits live in memory

Per-IP limits reset when the container restarts, so a deploy briefly clears them. Impact is
small: the control that matters — five wrong passwords burns the request — is counted in the
database.

### Fixed during this review

- **Tenant token was passed in `argv`** to `thinclient-enroll`. `/proc/<pid>/cmdline` is
  world-readable, so `ps` during an install leaked the token to any local user. It now travels in
  the environment (`TC_TENANT_TOKEN`), which only the process owner and root can read. Verified
  against production.

---

## 6. Turning it on, in order

1. **Flash the new ISO.** This is the one that actually matters — the gate is enforced *during
   installation*, so an ISO without `thinclient-enroll` cannot participate at all. Verified
   present in `iso/thinclient.iso` and byte-identical to source (`9c795cc2a53a61b4…`).
2. **Widen OTA 1.0.105 beyond rollout 0.** Matters for reinstalls of existing machines rather
   than for the gate itself.
3. **Decide gap 2 before gating anyone.** If you rely on pen-drive activation *after*
   installation, either build the first-boot prompt or switch those pen drives to route C
   (per-device credentials from the console).
4. **Gate Demo Tenant first and do one real install end to end.** It has no devices, so a mistake
   costs nothing.
5. **Then gate QUANTUM and leave it on.** New tenants already default to gated; only the three
   that existed before the change need switching.

---

## 7. Reference

| Component | Path |
|---|---|
| Approval logic, code generation | `thinclient-manager/src/lib/install.ts` |
| Device endpoints | `/api/install/request`, `/api/install/status`, `/api/install/claim` |
| Approval endpoints | `/api/install-requests`, `…/[id]/approve`, `…/[id]/deny` |
| Approval console | Dashboard → **Installations** |
| Tenant switch (super admin) | Tenant page → **Installation approval** |
| Device-side enrolment | `scripts/thinclient-enroll` |
| Installer hooks | `installer/install-to-disk.sh` §3b (identity), §5b (pen drive), §5d (approval) |
| Hardware-id binding | `thinclient-manager/src/lib/device-auth.ts` |
| Hardware fingerprint | `scripts/thinclient-firstboot` (`_hw_fingerprint`) |

**Note on `LICENSE_ENFORCE`.** The ISO ships `LICENSE_ENFORCE=false`, marked in
`config/license.conf` as a deliberate fail-safe. It means the licence kill-switch is inert on
anything installed from this image. Unrelated to the install gate, but worth a decision of its
own. (`thinclient-provision` defaults it to `true` when activating from a pen drive, so the two
paths disagree.)
