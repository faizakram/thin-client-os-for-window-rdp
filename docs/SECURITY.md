# Security

The appliance follows a **single-purpose, deny-by-default** model: the machine
can do exactly one thing (run the RDP client), and everything else is removed or
locked.

## Lockdown summary

| Surface | Control |
|---|---|
| Console login | Every `getty@tty1..6`, `serial-getty`, `console-getty` **masked** — no login prompt anywhere |
| VT switching | Xorg `DontVTSwitch` — Ctrl+Alt+F1..F12 do nothing; `logind` `NAutoVTs=1`, `ReserveVT=7` |
| X server "zap" | Xorg `DontZap` — Ctrl+Alt+Backspace cannot kill X |
| Window shortcuts | Openbox ships **only** the admin hotkey; Alt+Tab / Alt+F4 / menus are absent |
| FreeRDP breakout | `-grab-keyboard`, hidden floatbar — no client-side escape |
| Terminal | No terminal emulator reachable by the user (xterm exists only for admin-gated `nmtui`) |
| File manager | None installed |
| SSH | `openssh-server` not installed / purged; SSH disabled |
| Root | Password locked, shell set to `nologin` |
| Kiosk user | `thinclient` (uid 1000), password locked, shell `nologin`, **no general sudo** |
| sudo scope | `/etc/sudoers.d/thinclient` allows only a fixed command allowlist (validated with `visudo` at build) |
| Kernel | `kernel.sysrq=0`, `kernel.dmesg_restrict=1` |
| Package manager | `apt` present (needed for admin updates) but unreachable without the admin gate |
| Guest login | No display manager, no guest account |

## Admin authentication

- Password stored **only** as a salted SHA-512 crypt hash (`openssl passwd -6`)
  in `/etc/thinclient/admin.conf` (root:root, `0600`).
- Verification recomputes the hash with the stored salt and compares — plaintext
  is never persisted.
- Brute-force guard: `ADMIN_MAX_ATTEMPTS` failures → `ADMIN_LOCKOUT_SECONDS`
  lockout.

## Credential handling on the wire and at rest

- **On the wire:** `SECURITY=nla` (NLA) + TLS by default. Credentials are never
  sent in cleartext. Set `CERT_POLICY=tofu` to pin the server certificate on
  first use.
- **In the process table:** the RDP password is passed to FreeRDP via **stdin**
  (`/from-stdin:force`), never as an argv flag — it cannot be seen in `ps`.
- **At rest:** a stored `PASSWORD` in `server.conf` is recoverable from the raw
  disk. Mitigations:
  - Prefer **blank `PASSWORD`** (prompt on-screen) where a few seconds of user
    input per session is acceptable.
  - Use a **least-privilege RDP account**, not a domain admin, where possible.
  - Treat built ISOs and installed disks as **secrets**; control physical access.
  - Optionally enable **full-disk encryption** (LUKS) on the installed disk — the
    Plymouth theme already includes a password-prompt hook for it. This trades
    the zero-touch boot for at-rest protection.

> In this deployment the configured account is `Administrator` over a public IP.
> That maximizes convenience but also blast radius: anyone with the disk gets a
> high-privilege credential. If the threat model allows, create a dedicated,
> lower-privilege RDP user on the Windows server and use that instead.

## Network exposure

Phase 1 has **no VPN/bastion** — the client speaks RDP directly to the server
over TCP 3389. To reduce exposure:
- Restrict the Windows firewall to accept 3389 only from the thin-client
  subnet / source IPs.
- Keep NLA required on the server (rejects pre-auth attackers).
- Plan the VPN phase — see [FUTURE-VPN.md](FUTURE-VPN.md) — to remove direct
  internet exposure entirely.

## Build-time integrity

- The sudoers drop-in is validated with `visudo -cf` during the image build; a
  malformed rule **fails the build**.
- Package sources include Debian `security` and `updates`; run Admin Mode →
  **Update** periodically, or rebuild images on a schedule.
- The ISO ships with a `.sha256` checksum; verify it before writing to USB.

## What an attacker with physical access can still do

Physical access is always powerful. A stored password is extractable; a machine
can be booted from other media unless firmware is locked. Recommended hardening
for high-value sites: set a **BIOS/UEFI password**, disable external boot, and
enable **LUKS**. These are deployment choices layered on top of the OS.
