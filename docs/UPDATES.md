# Over-the-Air (OTA) Updates

ThinClient devices update themselves. Once a machine is installed to disk and
online, it checks a URL you control, verifies a **cryptographically signed**
release, applies it **atomically**, and **rolls back automatically** if the new
version fails to come up. You publish an update from your Mac with one command.

This document explains the whole flow, how to publish, and how the safety nets
work. Camera/USB/etc. are unrelated — this is only about updating the appliance
software (the `/opt/thinclient` scripts).

---

## 1. The moving parts

| Piece | Where | Role |
|-------|-------|------|
| `thinclient-update` | on the device, `/opt/thinclient/bin` | the updater; run by a timer |
| `thinclient-update.timer` | on the device | fires 2 min after boot, then every 6 h |
| `update-pubkey.pem` | on the device, `/etc/thinclient` | **public** key — verifies signatures |
| `update-signing-key.pem` | **your Mac only**, never shipped | **private** key — signs releases |
| `make-update-bundle.sh` | your Mac | packages + signs + publishes a release |
| GitHub Release | github.com | hosts `manifest`, `manifest.sig`, `thinclient-<ver>.tar.gz` |

The device only ever needs the **public** key. Anyone who has the ISO can read
that key — it cannot be used to forge an update. The **private** key is what
makes updates trustworthy; guard it (see §6).

---

## 2. Where updates are hosted — GitHub Releases

Each release is three files attached to a GitHub Release:

```
thinclient-1.1.0.tar.gz   # the payload: bin/ lib/ share/ assets/ VERSION
manifest                  # version=, bundle=, sha256=, rollout=, channel=
manifest.sig              # RSA-4096 signature of `manifest`, made with your private key
```

Devices fetch them from the release's **`latest/download`** alias, so you never
have to touch device config when you cut a new version:

```
UPDATE_URL = https://github.com/<owner>/<repo>/releases/latest/download
```

> **The releases repo must be PUBLIC.** GitHub only lets *unauthenticated*
> clients download release assets from public repos. The payload is just the
> appliance scripts — it contains **no secrets** (no RDP password, no keys), so
> a public repo is fine. Keep your *main* source repo private if you like and
> use a small separate public repo (e.g. `thinclient-releases`) just for
> releases. Point `UPDATE_URL` at whichever public repo hosts the releases.

You are not locked to GitHub. Any static host works — an S3 bucket, your own
web server, a CDN — as long as `GET <UPDATE_URL>/manifest` (and the other two
files) returns the bytes. GitHub Releases is just the zero-cost default.

---

## 3. Turning it on

Updates ship **disabled** so a fresh image never phones home unexpectedly. To
enable, set these in `/etc/thinclient/server.conf` **before you build the ISO**
(or edit them on an installed machine and reboot):

```ini
UPDATE_ENABLED=true
UPDATE_URL=https://github.com/<owner>/<repo>/releases/latest/download
UPDATE_CHANNEL=stable
UPDATE_ALLOW_UNSIGNED=false        # keep false — always require a signature
```

The timer is already enabled in the image; it is a **no-op** while
`UPDATE_ENABLED=false`, so shipping it costs nothing.

---

## 4. Publishing an update (from your Mac)

1. Make your code changes in this repo (edit `scripts/thinclient-*`, etc.).
2. Pick the next version number (semver, e.g. `1.0.0` → `1.1.0`).
3. Run the publisher:

   ```bash
   # build + sign locally only (inspect dist/update-1.1.0/ before shipping):
   ./make-update-bundle.sh 1.1.0

   # build + sign + upload to a GitHub release (needs the `gh` CLI, logged in):
   ./make-update-bundle.sh 1.1.0 --publish <owner>/<repo>

   # staged rollout — ship to ~25% of the fleet first, watch, then re-run at 100:
   ROLLOUT=25 ./make-update-bundle.sh 1.1.0 --publish <owner>/<repo>
   ```

That's it. Within ~6 hours (or on their next boot) devices in the rollout wave
pick it up, verify it, and switch over. There is nothing to do on the devices.

**Staged rollout** — `rollout=N` in the manifest means "only the N% of devices
whose stable hash falls in the wave". The bucket is
`sha256(machine-id + version) % 100`, so it's deterministic per device and
stable across retries: a machine that's "not in the wave" stays out until you
raise the percentage, and one that's "in" won't flip back out. Re-publish the
**same version** at a higher `ROLLOUT` to widen the wave (`--clobber` handles
the re-upload).

---

## 5. What happens on the device (the safety nets)

Every timer tick, `thinclient-update` runs this gauntlet. It **aborts safely**
at any step — the running version is never touched until the very last atomic
swap:

1. **Guards.** Skip if disabled, if no `UPDATE_URL`, if running from a live USB
   (updates only apply to installed disks), or if an RDP session is currently
   active (try again next tick — never interrupt the user).
2. **Fetch + verify signature.** Download `manifest` + `manifest.sig`. Verify the
   signature against `/etc/thinclient/update-pubkey.pem`. **A bad or missing
   signature aborts** — a man-in-the-middle who swaps the manifest can't forge
   the signature without your private key.
3. **Newer?** Compare versions (`sort -V`). Skip if we're already current or
   newer. Skip if this version previously failed here (blocklist, see below).
4. **Rollout gate.** Skip unless this device's bucket is inside the wave.
5. **Download + checksum.** Fetch the `.tar.gz`; abort if its `sha256` doesn't
   match the (signed) manifest — catches truncated/corrupted downloads.
6. **Stage + validate.** Unpack to `/opt/thinclient-releases/<ver>`; abort unless
   the expected files exist and every script passes a syntax check
   (`bash -n` / `py_compile`). A broken bundle never goes live.
7. **Atomic swap.** `/opt/thinclient` is a symlink; repoint it with an atomic
   `mv -T`. Every path that references `/opt/thinclient/...` flips in one step.
8. **Restart + health check.** Restart the session and watch for up to 90 s for
   the display server **and** the connect app to come back.
9. **Commit _or_ roll back.**
   - Healthy → keep it, prune to the two newest releases, stamp `build-info`.
   - Not healthy → **relink the previous release, restart, and add the bad
     version to a blocklist** so it's never retried on this machine.

Because the previous release is left fully intact on disk until commit, rollback
is just repointing the symlink — instant and total.

---

## 6. Key management (important)

- **`update-signing-key.pem` is the crown jewel.** Anyone with it can push code
  to every device. It is git-ignored and must **never** be committed or shared.
  Back it up somewhere safe and offline (a password manager / encrypted vault).
- **If it leaks or is lost:** generate a new keypair, ship the new
  `update-pubkey.pem` in the next ISO (a re-image), and sign all future releases
  with the new private key. Old devices keep trusting the old key until re-imaged.
- The keypair was created with:
  ```bash
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 -out update-signing-key.pem
  openssl rsa -in update-signing-key.pem -pubout -out config/update-pubkey.pem
  ```

---

## 7. Trying it without touching real devices

The full apply → rollback → tamper-rejection cycle is covered by
`tests/` (`scratchpad/test-ota.sh` in the working session) which runs the real
updater inside a container against `file://` bundles. Run it before shipping any
change to the updater.

---

## 8. Quick reference

```bash
# Publish v1.1.0 to the whole fleet
./make-update-bundle.sh 1.1.0 --publish <owner>/<repo>

# Staged: 10% first
ROLLOUT=10 ./make-update-bundle.sh 1.1.0 --publish <owner>/<repo>

# On a device — force a check now instead of waiting for the timer
sudo systemctl start thinclient-update.service
journalctl -u thinclient-update.service      # see what it did
cat /opt/thinclient/VERSION                    # current version
cat /var/lib/thinclient/updates/blocked        # versions that failed here
```
