# Configuration

Everything the appliance does is driven by **one file**:

```
/etc/thinclient/server.conf
```

Edit it (directly as root, or via Admin Mode → Configure) and the change takes
effect on the **next reconnect** — no reboot, no code changes. The launcher
re-reads the file on every connection attempt.

A second file, `/etc/thinclient/admin.conf` (root-only, `0600`), holds the admin
password hash and the secret hotkey — see [ADMIN.md](ADMIN.md).

## Format

`KEY=VALUE`, one per line. `#` starts a comment. Booleans accept
`true/false`, `1/0`, `yes/no`, `on/off`. Values may be quoted. The parser is
**safe** — it never executes the file, so a stray `$(...)` in a value is treated
as literal text.

## Key reference

### Connection
| Key | Default | Meaning |
|---|---|---|
| `SERVER_IP` | — | Windows server IP or hostname (**required**) |
| `PORT` | `3389` | RDP TCP port |
| `USERNAME` | — | Login user; empty ⇒ prompt on-screen |
| `PASSWORD` | — | Empty ⇒ prompt on-screen (**recommended**). If set, the file is auto-locked to `0640`. |
| `DOMAIN` | — | AD/NT domain (optional) |

### Network / WiFi
| Key | Default | Meaning |
|---|---|---|
| `WIFI_SSID` | — | Optional WiFi to auto-join on every machine. Blank = wired-only / use the picker. |
| `WIFI_PSK` | — | WiFi password (blank = open network). Stored in the image (root-only) — treat built images as secrets. |
| `NETWORK_GRACE` | `20` | Seconds to wait for ethernet/baked-WiFi/DHCP before showing the on-screen WiFi picker. |

Wired ethernet always auto-connects via DHCP with no configuration. See
[NETWORK.md](NETWORK.md) for the full WiFi behavior and the picker.

### Display
| Key | Default | Maps to |
|---|---|---|
| `FULLSCREEN` | `true` | `/f` (single monitor) |
| `MULTIMONITOR` | `true` | `/multimon` when >1 output is detected (overrides fullscreen) |
| `DYNAMIC_RESOLUTION` | `true` | `/dynamic-resolution` |

### Device redirection
| Key | Default | Maps to |
|---|---|---|
| `CLIPBOARD` | `true` | `/clipboard` |
| `SPEAKERS` | `true` | `/sound:sys:pulse` |
| `MICROPHONE` | `true` | `/microphone:sys:pulse` |
| `CAMERA` | `true` | `/video /camera` |
| `USB` | `false` | `/usb:auto` |
| `PRINTER` | `false` | `/printer` |
| `SMARTCARD` | `false` | `/smartcard` |

### Performance / visuals
| Key | Default | Maps to |
|---|---|---|
| `GPU` | `true` | `/gfx:AVC444 +gfx-h264` (else `/gfx:rfx`) |
| `BITMAP_CACHE` | `true` | `+bitmap-cache +glyph-cache /cache:codec:persistent` |
| `DESKTOP_COMPOSITION` | `true` | `+aero` |
| `FONT_SMOOTHING` | `true` | `+fonts` |
| `NETWORK_PROFILE` | `auto` | `/network:{auto,modem,broadband-high,wan,lan}` |

### Security
| Key | Default | Maps to |
|---|---|---|
| `SECURITY` | `nla` | `/sec:{nla,tls,rdp}` |
| `CERT_POLICY` | `tofu` | `/cert:tofu` (pin on first use) or `/cert:ignore` |

### Reconnect / watchdog
| Key | Default | Meaning |
|---|---|---|
| `AUTO_RECONNECT` | `true` | Retry forever when the session ends |
| `RECONNECT_INTERVAL` | `5` | Seconds between retries |
| `WATCHDOG_INTERVAL` | `5` | Watchdog health-check period |

### Escape hatch
| Key | Default | Meaning |
|---|---|---|
| `EXTRA_ARGS` | — | Raw FreeRDP flags appended verbatim. Advanced use. |

## Working with the config from the CLI

The `thinclient-config` tool (installed at `/opt/thinclient/bin/`) is the safe,
atomic way to read/modify values:

```bash
thinclient-config get SERVER_IP
thinclient-config set SERVER_IP 10.0.0.50      # atomic; preserves file mode
thinclient-config list                          # PASSWORD is redacted
thinclient-config validate                      # sanity-check the file
thinclient-config show-command                  # preview the FreeRDP command (password hidden)
```

## Password handling (important)

The password is **never** placed on the FreeRDP command line (it would appear
in `ps`). Instead it is streamed to FreeRDP over stdin via `/from-stdin:force`.

- **Blank `PASSWORD`** → the user types it on-screen each session. Most secure;
  nothing sensitive is stored in the image.
- **Stored `PASSWORD`** → true zero-touch boot, but the value is recoverable from
  the raw disk. Keep built images/disks as secrets, prefer a least-privilege RDP
  account, and rely on NLA+TLS so it is never sent in the clear. See
  [SECURITY.md](SECURITY.md).

## Example: low-bandwidth WAN profile

```ini
SERVER_IP=203.0.113.10
GPU=true
NETWORK_PROFILE=wan
DESKTOP_COMPOSITION=false
FONT_SMOOTHING=false
BITMAP_CACHE=true
EXTRA_ARGS=/gfx-progressive /compression-level:2
```
