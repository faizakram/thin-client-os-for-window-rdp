# Admin Guide

Day-to-day the appliance has no controls at all — that's the point. All
maintenance lives behind a hidden, password-gated **Admin Mode**.

## Opening Admin Mode

Press the secret hotkey from inside the RDP session:

```
Ctrl + Alt + Shift + A          (default; configurable)
```

A password box appears. Enter the administrator password. On success you get the
**Maintenance menu**; on failure you're silently returned to the session. Five
wrong attempts trigger a temporary lockout.

> Default admin password out of the box: **`changeme`** — change it before
> deployment (see below).

The RDP window stays running underneath; closing the menu returns focus to it.
The Linux desktop is never shown.

## Maintenance menu

| Action | What it does |
|---|---|
| **Configure** | GUI editor for server, credentials, and every device toggle. Includes **Test Connection**. Saving restarts the session to apply. |
| **Test** | Runs the connectivity + auth probe against the current server. |
| **Network** | Opens NetworkManager settings (Wi-Fi, static IP, DNS). |
| **Logs** | View `boot / rdp / watchdog / network / install` logs. |
| **Diagnostics** | Full system report; can save to an attached USB stick. |
| **Update** | `apt-get update && upgrade` with live output. |
| **Restart** | Restart the RDP session immediately. |
| **Reboot** | Reboot the thin client. |
| **Return** | Back to the Remote Workspace. |

## Changing the server (no Linux knowledge needed)

Admin Mode → **Configure** → change *Server IP / Host* (and username/domain if
needed) → **Save & Apply**. The session reconnects to the new target within a few
seconds.

Equivalent CLI (during provisioning, as root):
```bash
thinclient-config set SERVER_IP 10.0.0.50
thinclient-config set USERNAME  developer
systemctl restart thinclient-x.service
```

## Changing the admin password

**During provisioning (recommended):**
```bash
sudo thinclient-adminctl set-password      # prompts twice, writes the $6$ hash
```

**Baked into the image at build time:**
```bash
./scripts/gen-admin-hash.sh                # prints ADMIN_PASSWORD_HASH=...
# paste into config/admin.conf before running build.sh
```

The password is stored only as a salted SHA-512 crypt hash in
`/etc/thinclient/admin.conf` (root-only, `0600`). Plaintext is never written.

## Changing the secret hotkey

Edit `ADMIN_HOTKEY` in `/etc/thinclient/admin.conf` using Openbox key syntax
(`C-A-S-a` = Ctrl+Alt+Shift+A). It is applied at the next session start
(the Openbox config is re-rendered from the template on every launch).

## Privilege model

The `thinclient` user has **no general sudo**. It may run only a fixed allowlist
(session restart, reboot/poweroff, `apt-get update/upgrade`, `nmcli/nmtui`) via
`/etc/sudoers.d/thinclient`, and only after the Admin-Mode password gate. Because
the session exposes no shell or terminal, those commands are unreachable outside
Admin Mode. See [SECURITY.md](SECURITY.md).

## Services cheat-sheet

```bash
systemctl status  thinclient-x.service          # the kiosk session
systemctl status  thinclient-watchdog.service   # the supervisor
systemctl restart thinclient-x.service          # reconnect now
journalctl -u thinclient-x.service -b           # session logs this boot
```

Application logs (rotated daily, 7 kept) live in `/var/log/thinclient/`.
