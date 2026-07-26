# Troubleshooting

Start with a full snapshot: Admin Mode → **Diagnostics**, or on a shell
`/opt/thinclient/bin/thinclient-diagnostics`. Logs live in
`/var/log/thinclient/` (`boot`, `rdp`, `watchdog`, `network`, `install`).

## Symptom → fix

### Stuck on "Connecting to Remote Workspace…" forever
The server is unreachable or auth is failing. Check:
```bash
thinclient-test-connection            # TCP + auth probe with diagnostics
tail -n 50 /var/log/thinclient/rdp.log
```
- **TCP UNREACHABLE** → server off, wrong IP, firewall blocking 3389, or no
  network. Verify with Admin Mode → **Network**, and `thinclient-netctl status`.
- **auth FAILED** → wrong `USERNAME`/`PASSWORD`/`DOMAIN`, or the account isn't
  allowed Remote Desktop on the server. Fix via Admin Mode → **Configure**.

### WiFi picker keeps appearing / can't get online
The machine has no usable network. From the picker: verify the password, use
**Rescan**, or plug in Ethernet (the picker closes automatically when a cable is
detected). If a baked WiFi is configured but wrong, fix `WIFI_SSID`/`WIFI_PSK`
via Admin Mode → Configure. See [NETWORK.md](NETWORK.md).

### Stuck on "Connecting…" but the WiFi picker never appears
The box believes it has a network (a default route exists) but can't reach the
RDP server — so it keeps retrying RDP rather than asking for WiFi. This is a
server/firewall problem, not networking; use `thinclient-test-connection`.

### Black screen after boot (no splash, no RDP)
X may have failed to start.
```bash
systemctl status thinclient-x.service
journalctl -u thinclient-x.service -b | tail -n 60
```
Common causes:
- **`Xwrapper`**: ensure `/etc/X11/Xwrapper.config` has `allowed_users=anybody`.
- **GPU/driver**: try removing `xserver-xorg-video-*` mismatch, or add
  `nomodeset` to the kernel cmdline for stubborn GPUs.
- The watchdog should restart the session automatically within ~15 s; watch
  `tail -f /var/log/thinclient/watchdog.log`.

### Screen blanks / goes to a black console after idle
DPMS/blanking slipped through.
- Confirm `/etc/X11/xorg.conf.d/10-thinclient-kiosk.conf` is present (sets
  `BlankTime 0`, DPMS disabled).
- The session also runs `xset s off -dpms s noblank` at start.

### No audio / microphone / camera in the Windows session
- Toggle is off: set `SPEAKERS`/`MICROPHONE`/`CAMERA=true` in Configure.
- PipeWire not ready: `systemctl --user status pipewire` (as `thinclient`), or
  check the device is enumerated (`v4l2-ctl --list-devices` for camera).
- The Windows server must permit that redirection in its RDP policy.

### Multi-monitor not spanning
`/multimon` is only added when **>1 connected output** is detected at session
start. Verify with `xrandr --query`. If a monitor is connected after boot,
restart the session (Admin → **Restart**).

### Clipboard doesn't work
`CLIPBOARD=true` must be set **and** the Windows server must allow clipboard
redirection (Group Policy / RDP settings).

### Admin hotkey does nothing
- Confirm the combo matches `ADMIN_HOTKEY` in `/etc/thinclient/admin.conf`.
- The Openbox config is re-rendered each session; restart the session after
  changing the hotkey.
- If yad is missing the menu can't show — reinstall `yad`.

### "Incorrect password" even when correct / locked out
- Five failures trigger a lockout (`ADMIN_LOCKOUT_SECONDS`). Wait it out, or as
  root remove `/run/thinclient/admin.lock`.
- If the hash is wrong, reset it: `sudo thinclient-adminctl set-password`.

### Boot is slow (> 15 s)
- Use SSD + UEFI. The installer already sets `GRUB_TIMEOUT=1`.
- Slow network delaying `network-online.target`? FreeRDP fails fast into the
  retry loop; you can also relax the `After=network-online.target` dependency.
- Check `systemd-analyze blame` for the worst offenders.

### Watchdog keeps restarting the session
Something is genuinely unhealthy (launcher not heartbeating). Inspect:
```bash
tail -n 100 /var/log/thinclient/watchdog.log
tail -n 100 /var/log/thinclient/rdp.log
```
If FreeRDP dies instantly every time (bad config, server rejecting), fix the
config; the loop backs off but won't hide a real error in the logs.

## Building / ISO issues

### `build.sh` says it must run as root / on Linux
Use the Docker builder from macOS/Windows: `make iso`. Natively, `sudo ./build.sh`
on a Debian/Ubuntu host with `live-build` installed.

### live-build fails on mount / loop devices (in Docker)
The builder container must be **privileged** (it is, in `docker-compose.yml`).
On Docker Desktop, ensure the VM has enough disk (≥ 10 GB free).

### Tests
```bash
make test          # shellcheck + unit suites in a container
```

## Getting help fast
Collect and share the diagnostics bundle:
```bash
/opt/thinclient/bin/thinclient-diagnostics --save   # writes to USB or /var/log/thinclient
```
