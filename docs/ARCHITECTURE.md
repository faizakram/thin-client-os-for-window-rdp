# Architecture

ThinClient OS is a single-purpose Debian 13 appliance. Its only job is to run a
full-screen FreeRDP session against a Windows server and keep it alive forever,
while never exposing any part of Linux to the user.

## Components

| Layer | Component | Role |
|---|---|---|
| Firmware | GRUB (BIOS + UEFI) | Boots the kernel silently |
| Boot UX | Plymouth (`thinclient` theme) | Dark splash; hides all boot text |
| Init | systemd (`graphical.target`) | Brings up exactly three services |
| Session | `thinclient-x.service` | Launches X on VT7 → Openbox → RDP loop |
| Reconnect | `thinclient-session` | Forever-loop that runs FreeRDP + splash |
| Network gate | `thinclient-netwait` + `thinclient-wifi` | Ensures a network before RDP; shows the locked-down WiFi picker when offline |
| RDP | `xfreerdp3` (FreeRDP 3) | The actual Windows connection |
| Supervisor | `thinclient-watchdog.service` | Restarts the session on a stale heartbeat |
| Prep | `thinclient-firstboot.service` | Dirs, permissions, log seeding |
| Config | `/etc/thinclient/server.conf` | The single source of truth |
| Admin | `thinclient-adminmode` (hotkey) | Password-gated maintenance |

Everything the appliance runs lives under `/opt/thinclient/` (`bin/`, `lib/`,
`share/`, `assets/`, `docs/`). Configuration lives under `/etc/thinclient/`.
Logs live under `/var/log/thinclient/`.

## Supervision model (three independent safety nets)

1. **FreeRDP `/auto-reconnect`** — recovers brief network blips *within* a session.
2. **`thinclient-session` loop** — if FreeRDP exits, re-launches it after
   `RECONNECT_INTERVAL`, showing the "Connecting…" splash in between.
3. **`thinclient-watchdog`** — if the whole session wedges (heartbeat goes
   stale), it `systemctl restart`s `thinclient-x.service`.
4. **systemd `Restart=always`** — if X itself dies, systemd relaunches it.

No single failure leaves the user looking at Linux.

---

## Diagram 1 — Overall architecture

```mermaid
flowchart TB
    subgraph Client["Linux Thin Client (this appliance)"]
        GRUB --> Kernel --> systemd
        systemd --> FB["thinclient-firstboot.service"]
        systemd --> X["thinclient-x.service<br/>(xinit → Openbox)"]
        systemd --> WD["thinclient-watchdog.service"]
        X --> SESS["thinclient-session<br/>(reconnect loop)"]
        SESS --> RDP["xfreerdp3"]
        CONF[("/etc/thinclient/server.conf")] -. read every attempt .-> SESS
        WD -. restarts on stale heartbeat .-> X
        SESS -. heartbeat .-> WD
    end
    RDP -- "RDP / TCP 3389 (NLA+TLS)" --> WIN["Windows Development Server"]
```

## Diagram 2 — Boot process

```mermaid
flowchart TB
    A["Power ON"] --> B["GRUB (hidden, 1s)"]
    B --> C["Linux kernel + initramfs"]
    C --> D["Plymouth splash (dark)"]
    D --> E["systemd → graphical.target"]
    E --> F["thinclient-firstboot.service<br/>dirs • perms • logs"]
    F --> G["thinclient-x.service starts X on VT7"]
    G --> H["Openbox WM"]
    H --> I["thinclient-session loop"]
    I --> N{"network gate<br/>online?"}
    N -- no --> P["WiFi picker / wait"]
    P --> N
    N -- yes --> J["Connecting… splash"]
    J --> K["xfreerdp3 fullscreen"]
    K --> L["Windows desktop"]
    style A fill:#0b1220,color:#fff
    style L fill:#1f6feb,color:#fff
```

## Diagram 3 — Login flow

```mermaid
flowchart LR
    subgraph NoInteractiveLogin["No console / no display manager"]
        direction TB
        A["systemd graphical.target"] --> B["thinclient-x.service<br/>User=thinclient (uid 1000)"]
        B --> C["PAM 'login' session<br/>→ seat + XDG_RUNTIME_DIR"]
        C --> D["xinit → Openbox → session"]
    end
    E["getty@tty1..6"] -. masked .-> X1["(no login prompt)"]
    F["root"] -. locked, nologin .-> X2["(no root login)"]
```

## Diagram 4 — RDP flow

```mermaid
sequenceDiagram
    participant S as thinclient-session
    participant C as server.conf
    participant B as rdp-build-args.sh
    participant F as xfreerdp3
    participant W as Windows server
    S->>C: read SERVER_IP, creds, toggles
    S->>B: tc_build_rdp_args()
    B-->>S: TC_RDP_ARGS[] + TC_RDP_PASSWORD
    S->>F: exec xfreerdp3 (args) , password via stdin
    F->>W: TCP 3389 + NLA/TLS handshake
    W-->>F: desktop session (H.264/GFX)
    Note over F,W: clipboard • audio • mic • camera • USB (per config)
    W--xF: server reboot / logoff
    F-->>S: process exits
    S->>S: show splash, wait RECONNECT_INTERVAL, retry
```

## Diagram 5 — Watchdog flow

```mermaid
flowchart TB
    A["every WATCHDOG_INTERVAL (5s)"] --> B{"thinclient-x.service active?"}
    B -- no --> A
    B -- yes --> C["read heartbeat age + launcher pid"]
    C --> D{"age > 3×interval (min 15s)<br/>OR launcher missing?"}
    D -- no --> A
    D -- yes --> E["log WARN + kill stray xfreerdp"]
    E --> F["systemctl restart thinclient-x.service"]
    F --> G["wait restart_grace (20s)"]
    G --> A
```

## Diagram 6 — Auto-reconnect

```mermaid
stateDiagram-v2
    [*] --> Connecting
    Connecting: show "Connecting to Remote Workspace…"
    Connecting --> Connected: xfreerdp3 established
    Connected --> Disconnected: session ends (reboot / logoff / blip)
    Disconnected --> Wait: AUTO_RECONNECT=true
    Wait --> Connecting: after RECONNECT_INTERVAL
    Disconnected --> Hold: AUTO_RECONNECT=false
    Hold: hold on splash (never show desktop)
    Hold --> [*]
```

## Diagram 7 — Admin mode

```mermaid
flowchart TB
    A["Ctrl+Alt+Shift+A (Openbox keybind)"] --> B["thinclient-adminmode"]
    B --> C{"password prompt"}
    C -- wrong --> D["deny → return to session"]
    C -- locked --> E["lockout message → return"]
    C -- correct --> F["Maintenance menu (yad)"]
    F --> G["Configure"]
    F --> H["Test connection"]
    F --> I["Network settings"]
    F --> J["View logs"]
    F --> K["Diagnostics"]
    F --> L["Update packages"]
    F --> M["Restart / Reboot"]
    G & H & I & J & K & L & M --> N["close menu → back to RDP"]
```

## Diagram 8 — Deployment process

```mermaid
flowchart LR
    A["build.sh / make iso"] --> B["thinclient.iso"]
    B --> C["dd → USB stick"]
    C --> D["Boot reference PC (live)"]
    D --> E["Admin → Configure server"]
    E --> F["thinclient-install /dev/sda"]
    F --> G["Reference machine boots from disk"]
    G --> H["Clonezilla: capture image"]
    H --> I["Clonezilla: restore to fleet (N machines)"]
    I --> J["Per-site: adjust server.conf if needed"]
```

See [CONFIGURATION.md](CONFIGURATION.md) for every tunable, and
[RECOVERY.md](RECOVERY.md) for the failure/recovery matrix.
