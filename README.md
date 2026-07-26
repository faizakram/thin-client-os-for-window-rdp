# ThinClient OS — a Debian 13 RDP appliance

A production-grade, locked-down Linux operating system that boots straight into
a **full-screen Windows RDP session** and nothing else. The user never sees
Linux: no desktop, no taskbar, no terminal, no login prompt. Power on → a brief
splash → *"Connecting to Remote Workspace…"* → their Windows desktop.

Think IGEL / HP ThinPro / Dell Wyse / Stratodesk, tailored for one job: a
dedicated FreeRDP client for a Windows development server.

```
Power ON → Debian boots → systemd starts X on VT7 → Openbox → FreeRDP (fullscreen)
            └── watchdog supervises ── reconnect loop retries forever ──┘
```

---

## What you get

| Capability | How |
|---|---|
| Boots into fullscreen RDP, no desktop ever | systemd-supervised X session (`thinclient-x.service`) → Openbox → FreeRDP 3 |
| Reconnect forever (server reboots, network blips) | Outer reconnect loop + FreeRDP `/auto-reconnect` |
| Self-healing | `thinclient-watchdog.service` restarts the session on a stale heartbeat |
| Zero-code reconfiguration | Everything reads `/etc/thinclient/server.conf` |
| Hidden admin panel | Secret hotkey (**Ctrl+Alt+Shift+A**) → password → GUI |
| Locked down | No shell, no VT switching, no zap, no SSH, no sudo for the user, root disabled |
| Full RDP feature set | Multi-monitor, dynamic resolution, clipboard, audio, mic, camera, USB, printer, GPU/H.264 |
| WiFi without a desktop | Ethernet auto-connects; optional baked WiFi; a locked-down WiFi picker appears automatically when offline |
| Reproducible image | `./build.sh` → `iso/thinclient.iso` (BIOS + UEFI hybrid) |
| Testable without hardware | Docker build + test environment, unit tests, `test-rdp.sh` |

---

## Quick start

### 1. Build the ISO

The deployable image for typical (x86) thin clients is **amd64**.

```bash
make iso                       # Docker builder → iso/thinclient.iso (BIOS+UEFI)
```
This works on **macOS (incl. Apple Silicon)**, Windows, and Linux. On Apple
Silicon it runs the amd64 build under emulation (slower but verified working).

Faster on an amd64 Linux host (cloud VM, spare PC, WSL2/x86, CI):
```bash
./bootstrap-build-host.sh      # installs live-build + builds natively
#   or, if the toolchain is present:  sudo ./build.sh
```

> The builder writes the root filesystem to a **Docker volume**, not the source
> tree — debootstrap can't build a Linux rootfs on a macOS bind mount. This is
> handled automatically. Details + `make iso-native` (arm64 test build):
> [docs/BUILDING.md](docs/BUILDING.md).

Output: `iso/thinclient.iso` (+ `.sha256`).

### 2. Point it at your server

Copy the template to create your real config (kept out of git, so credentials
never land in the repo), then edit it — or edit
`/etc/thinclient/server.conf` on a running unit via Admin Mode:

```bash
cp config/server.conf.example config/server.conf
```
Minimum:
```ini
SERVER_IP=192.168.1.20
PORT=3389
USERNAME=developer
PASSWORD=            # leave blank to prompt on-screen (more secure)
```
> `config/server.conf` is `.gitignore`d because it holds credentials.
> `build.sh` auto-creates it from the template if missing.

### 3. Boot it

```bash
# Write to a USB stick (replace /dev/sdX with your device)
sudo dd if=iso/thinclient.iso of=/dev/sdX bs=4M status=progress oflag=sync
```
Boot the target machine from USB. It comes up straight into the RDP session.

### 4. Install to disk & clone the fleet

From the live session, open Admin Mode (**Ctrl+Alt+Shift+A**) or run:
```bash
sudo thinclient-install /dev/sda      # persist to the internal disk
```
Then clone the reference machine to the fleet with Clonezilla —
see [docs/CLONEZILLA.md](docs/CLONEZILLA.md).

---

## Repository layout

```
thin-client-os-for-window-rdp/
├── build.sh                 # ISO builder (live-build orchestrator)
├── test-rdp.sh              # probe/verify a real RDP server
├── Makefile                 # docker wrappers: make iso | test | shell
├── config/                  # server.conf, admin.conf, xorg, openbox, sudoers…
│   └── live-build/          # package lists + chroot customization hook
├── scripts/                 # all appliance runtime scripts (→ /opt/thinclient)
│   └── lib/                 # shared bash libraries (config parser, RDP builder)
├── systemd/                 # the three services (x, watchdog, firstboot)
├── assets/                  # Plymouth boot theme + branding
├── installer/               # install-to-disk
├── docker/                  # build + test container definitions
├── tests/                   # unit tests + lint + runner
├── docs/                    # full documentation set (see below)
└── iso/                     # build output
```

## Documentation

| Doc | Contents |
|---|---|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Components, boot flow, all Mermaid diagrams |
| [docs/BUILDING.md](docs/BUILDING.md) | Build matrix, host-arch requirements, build knobs |
| [docs/CONFIGURATION.md](docs/CONFIGURATION.md) | Every `server.conf` key and how it maps to FreeRDP |
| [docs/NETWORK.md](docs/NETWORK.md) | Ethernet/WiFi behavior, the offline WiFi picker, baked WiFi |
| [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) | Building, USB, installing to disk |
| [docs/CLONEZILLA.md](docs/CLONEZILLA.md) | Fleet cloning workflow |
| [docs/ADMIN.md](docs/ADMIN.md) | Admin Mode, the GUI tool, changing servers/passwords |
| [docs/RECOVERY.md](docs/RECOVERY.md) | Watchdog, auto-reconnect, self-healing behavior |
| [docs/SECURITY.md](docs/SECURITY.md) | Lockdown model, threat notes, hardening |
| [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | Symptoms → fixes, log locations |
| [docs/FUTURE-VPN.md](docs/FUTURE-VPN.md) | Phase-2 VPN integration design |

## Testing

```bash
make test                 # shellcheck + unit suites in a container
./test-rdp.sh             # probe the configured RDP server (TCP + auth)
./test-rdp.sh --session   # also open a real FreeRDP window (needs X)
```

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for how it all fits together.
