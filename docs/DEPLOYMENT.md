# Deployment

Three stages: **build the ISO → boot a reference machine → install to disk →
clone the fleet**.

```mermaid
flowchart LR
    A[build.sh] --> B[thinclient.iso] --> C[USB] --> D[Reference PC]
    D --> E[thinclient-install] --> F[Clonezilla capture] --> G[Fleet restore]
```

## 1. Build the ISO

### Option A — Docker (macOS / Windows / any host)
```bash
make iso            # → iso/thinclient.iso
```
The build runs in a **privileged** Debian container (live-build needs loop
devices). First run downloads the base system and can take 15–40 minutes.

### Option B — native (Debian/Ubuntu host)
```bash
sudo apt-get update && sudo apt-get install -y live-build
sudo ./build.sh
```

Useful flags: `./build.sh --clean`, `./build.sh --rebuild`.
Environment overrides: `TC_DIST` (default `trixie`), `TC_MIRROR`, `TC_VERSION`.

Output:
```
iso/thinclient.iso
iso/thinclient.iso.sha256
```

## 2. Bake in your server (before or after build)

Edit [config/server.conf](../config/server.conf) **before** building to bake the
target in, or configure it later per-machine via Admin Mode. To set a non-default
admin password into the image before building:

```bash
./scripts/gen-admin-hash.sh            # prints ADMIN_PASSWORD_HASH=...
# paste that line into config/admin.conf, replacing the default hash
```

## 3. Write to USB and boot the reference machine

```bash
# Linux
sudo dd if=iso/thinclient.iso of=/dev/sdX bs=4M status=progress oflag=sync

# macOS (diskutil to find the disk, then dd to the raw device)
diskutil list
diskutil unmountDisk /dev/diskN
sudo dd if=iso/thinclient.iso of=/dev/rdiskN bs=4m
```
Or use balenaEtcher / Rufus (write in **DD/image** mode, not ISO mode).

Boot the target from USB. It comes straight up into the RDP session. If you did
not bake the server in, open Admin Mode (**Ctrl+Alt+Shift+A**, default password
`changeme`) → **Configure** and set it.

## 4. Install to the internal disk

From the live session, open Admin Mode → (or, if you have shell access during
provisioning) run:

```bash
sudo thinclient-install /dev/sda      # DESTROYS the target disk
```

This partitions (EFI + ext4), copies the system, installs GRUB for both UEFI and
BIOS, removes the live-only packages, and rebuilds the initramfs. Reboot, remove
the USB, and the machine now boots the appliance from local disk.

## 5. Clone the fleet

Turn the reference machine into an image and restore it onto the rest — see
[CLONEZILLA.md](CLONEZILLA.md).

## Boot-time targets

- **Boot ≤ 15 s** on reasonable hardware (SSD + UEFI). The biggest levers are
  fast storage and `GRUB_TIMEOUT=1` (already set by the installer).
- If a machine is slow to reach the network, FreeRDP fails fast (`/timeout:15000`)
  into the "Connecting…" retry loop rather than hanging.

## Verifying a deployment

```bash
./test-rdp.sh                 # from the repo or on the appliance: TCP + auth probe
./test-rdp.sh --session       # open a real windowed FreeRDP session (needs X)
```
On the appliance, Admin Mode → **Diagnostics** produces a full report (and can
save it to a USB stick).
