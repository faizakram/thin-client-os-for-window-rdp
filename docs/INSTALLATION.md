# ThinClient OS — Installation Guide

**For:** IT / deployment team
**Image:** `thinclient.iso` — **version 1.0.22**
**SHA-256:** `dc8e0b8c393b9a20add71212d1a0f44319b735eaee6b4e0355d7bb9f359322c6`

This guide covers flashing the image to a USB stick, installing it to a machine's
internal disk, first-time setup, and rolling out a fleet.

> ⚠️ **Install to the internal disk — don't run from the USB.**
> A USB "live" boot is temporary: every reboot wipes all settings (saved RDP
> credentials, etc.). Only a **disk install** persists. See [Step 3](#step-3--install-to-the-internal-disk).

---

## 1. What you need

| Item | Notes |
|------|-------|
| The image | `thinclient.iso` (v1.0.22) — provided separately |
| USB stick | **8 GB or larger** (its contents will be erased) |
| Target machine | x86-64 PC/mini-PC, boots from USB, wired or Wi-Fi network |
| Network | Reachable path to your RDP server and to `manager.esparksit.com` |

**Verify the image first** (optional but recommended):

- Windows (PowerShell): `Get-FileHash .\thinclient.iso -Algorithm SHA256`
- macOS / Linux: `shasum -a 256 thinclient.iso`

The result must equal the SHA-256 above.

---

## 2. Flash the image to the USB

Pick whichever tool you have. **All data on the USB stick is erased.**

### Option A — balenaEtcher (Windows / macOS / Linux, easiest)
1. Open **balenaEtcher**.
2. **Flash from file** → select `thinclient.iso`.
3. **Select target** → choose the USB stick.
4. **Flash** and wait for it to finish + verify.

### Option B — Rufus (Windows)
1. Open **Rufus**, select the USB device.
2. **SELECT** → `thinclient.iso`.
3. Leave defaults, keep **DD Image mode** if prompted, click **START**.

### Option C — command line (macOS / Linux)
```bash
# macOS: find the disk, e.g. /dev/disk4
diskutil list
diskutil unmountDisk /dev/diskN
sudo dd if=thinclient.iso of=/dev/rdiskN bs=4m && sync

# Linux: find the disk, e.g. /dev/sdX
lsblk
sudo dd if=thinclient.iso of=/dev/sdX bs=4M status=progress oflag=sync
```
> Double-check the target disk name — `dd` writes with no confirmation.

---

## 3. Boot the target machine from USB

1. Insert the USB stick.
2. Power on and open the **boot menu** (usually `F12`, `F10`, `Esc`, or `F2` for
   BIOS — varies by vendor).
3. Choose the USB device.
4. The appliance boots to a **lock screen**, then the **connection screen**.
   - Default lock password (factory): **`0000`** — change it later in Admin Mode.

If it boots into your normal OS instead, enable USB boot / disable Secure Boot in
BIOS and retry.

---

## 4. Install to the internal disk

This copies the OS onto the machine's disk so settings persist across reboots.

1. From the running (USB) session, open the diagnostic console:
   **`Ctrl` + `Alt` + `F2`** → log in `esparks` / `esparks`.
2. Run the installer:
   ```bash
   sudo thinclient-install
   ```
   - It lists the disks and asks which to install to (or pass it directly:
     `sudo thinclient-install /dev/sda`).
   - It wipes the chosen disk, copies the system, and installs the bootloader.
   - **This erases the target disk** — make sure it's the right machine/disk.
3. When it finishes, **shut down, remove the USB stick**, and power on again.
   The machine now boots from its internal disk.

---

## 5. First boot + configure

On the installed machine:

1. **Unlock** — enter the lock password (default `0000`).
2. **Network** — if there's no wired connection, click **Wi-Fi…** on the
   connection screen and join your network.
3. **Enter the connection** — the form is blank on a brand-new device:
   - **Server / IP** — your Windows RDP server address
   - **Username**
   - **Password**
   - Port defaults to **3389**
4. Click **Connect**.
5. After a successful session, the IP + username + password are **saved on this
   device** and auto-filled every time afterwards. They survive reboots and stay
   until you change them (connecting with new details replaces them).

The device **auto-enrolls** into your fleet (tenant **QUANTUM**) and appears in
**manager.esparksit.com**, where you can set its timezone, recording, and more.
Timezone and policy are pushed from the manager automatically.

---

## 6. Roll out a fleet (fast)

Instead of configuring every machine by hand:

1. Install + fully configure **one master** machine (Steps 3–5).
2. **Clone** its disk to the rest with Clonezilla — see
   [CLONEZILLA.md](CLONEZILLA.md).

Each clone comes up already configured. (Each device still gets its own identity
in the manager on first boot.)

---

## 7. Admin & everyday operation

| Action | How |
|--------|-----|
| **Admin Mode** (change settings, server, lock password) | `Ctrl` + `Alt` + `Shift` + `A` |
| **Lock the screen** | `Super` (Windows key) + `L` |
| **Check the OS version** | `Ctrl`+`Alt`+`F2` → `esparks`/`esparks` → `cat /opt/thinclient/VERSION` |
| **Software updates** | Automatic. A prompt appears **on the connection screen** when a new version is available; accept it and the screen refreshes. |
| **Fleet management** | manager.esparksit.com (timezone, recording, reboot, live view) |

**Updates note:** over-the-air updates deliver software fixes to already-deployed
machines. The connection-form defaults (blank first-time fields) are part of the
**image only** — re-flash to pick those up on a fresh device; existing devices
remember what they last used, so they don't need it.

---

## 8. Troubleshooting

| Symptom | Do this |
|---------|---------|
| Won't boot from USB | Enable USB boot / disable Secure Boot in BIOS; re-flash the USB. |
| Saved password lost after reboot | The machine is running from **USB**, not installed. Do [Step 4](#step-4--install-to-the-internal-disk). |
| Clock shows the wrong time | Set the timezone for the device/tenant in the manager; it applies on the next poll. |
| Capture a diagnostic | `Ctrl`+`Alt`+`F2` → `esparks`/`esparks` → run **`getlogs`**, photograph the screen, send to support. |

More detail: [TROUBLESHOOTING.md](TROUBLESHOOTING.md) · [RECOVERY.md](RECOVERY.md) ·
[ADMIN.md](ADMIN.md) · [DEPLOYMENT.md](DEPLOYMENT.md)

---

## Quick reference

- **Image:** `thinclient.iso` v1.0.22 · SHA-256 `dc8e0b8c…59322c6`
- **Install:** boot USB → `Ctrl`+`Alt`+`F2` (`esparks`/`esparks`) → `sudo thinclient-install` → reboot without USB
- **Default lock password:** `0000`
- **Admin Mode:** `Ctrl`+`Alt`+`Shift`+`A`
- **Manager:** manager.esparksit.com (tenant QUANTUM)
