# Claude Code – Build a Production Ready Linux Thin Client OS for Windows RDP

## ROLE

You are acting as:

* Senior Linux Kernel Engineer
* Debian Maintainer
* DevOps Engineer
* Systems Architect
* Security Engineer
* Kiosk OS Engineer
* RDP/FreeRDP Expert

Your goal is to build a complete production-ready Linux Thin Client operating system.

This is **not a demo**.

This project will be deployed to hundreds of developer machines.

Every script, configuration, documentation, and service should be production quality.

---

# PROJECT GOAL

Create a bootable Debian 13 based operating system that behaves like a dedicated RDP appliance.

The operating system should be completely invisible to the end user.

When the PC powers on:

```
Power ON
      ↓
Debian Boots
      ↓
Auto Login
      ↓
Openbox (or no desktop)
      ↓
Auto Launch FreeRDP
      ↓
Connect to Windows Server
      ↓
Full Screen
      ↓
User Works Normally
```

The user should never know Linux exists.

---

# PHASE 1 ARCHITECTURE

No VPN

No Bastion

No Jump Server

No Gateway

Only

```
Linux Thin Client
        │
        │  RDP (TCP 3389)
        │
        ▼
Windows Development Server
```

Everything runs on the Windows server.

The Linux machine is only an RDP appliance.

---

# PRIMARY OBJECTIVES

The system must

* Boot in under 15 seconds (reasonable hardware)
* Auto Login
* Auto Launch RDP
* Full Screen
* Auto Reconnect
* Never expose Linux Desktop
* Never expose Terminal
* Never expose File Manager
* Never expose Settings
* Never expose Package Manager

---

# CONFIGURATION

The RDP connection **must NOT be hardcoded**.

Instead create a configurable configuration file.

Example

```
/etc/thinclient/server.conf
```

Example

```ini
SERVER_IP=192.168.1.20
PORT=3389
USERNAME=developer
PASSWORD=
DOMAIN=
FULLSCREEN=true
MULTIMONITOR=true
CAMERA=true
MICROPHONE=true
SPEAKERS=true
CLIPBOARD=true
USB=false
PRINTER=false
AUTO_RECONNECT=true
RECONNECT_INTERVAL=5
```

Changing this file should immediately change the target server.

No code modification should ever be required.

---

# OPTIONAL GUI CONFIGURATION TOOL

Create a lightweight admin configuration tool.

Only accessible using an administrator password.

Features:

* Change Server IP
* Change Port
* Change Username
* Change Domain
* Enable/Disable Camera
* Enable/Disable Audio
* Enable/Disable Clipboard
* Enable/Disable USB
* Test Connection
* Save Configuration

No Linux knowledge required.

---

# RDP FEATURES

Use latest FreeRDP.

Support

* Full Screen
* Dynamic Resolution
* Multiple Monitor
* Clipboard
* Camera Redirection
* Microphone
* Audio
* Smart Reconnect
* TLS
* NLA
* GPU if available
* Bitmap Cache
* Desktop Composition
* Font Smoothing

---

# USER EXPERIENCE

The user should feel they are using Windows locally.

No visible Linux desktop.

No wallpaper.

No taskbar.

No dock.

No desktop icons.

No notifications.

No update popups.

No shell.

No login prompts.

No command line.

No flashing windows.

---

# AUTO RECOVERY

If RDP exits

Automatically restart.

If Windows Server reboots

Reconnect forever.

Display only

```
Connecting to Remote Workspace...
```

No Linux desktop should ever appear.

---

# SECURITY

Disable

* Ctrl+Alt+F1-F12
* Alt+Tab
* Alt+F4
* Terminal
* SSH
* Package Manager
* File Browser
* Root Login
* Guest Login

Single locked-down user.

No sudo.

---

# WATCHDOG

Create a watchdog service.

Every 5 seconds

Check

Is xfreerdp running?

If not

Restart immediately.

---

# ADMIN MODE

Create a hidden maintenance mode.

Accessible only by password or secret key combination.

Admin mode should allow

* Network Settings
* Update Packages
* View Logs
* Change Server
* Restart Services
* Diagnostics

Exit Admin Mode

Automatically return to RDP.

---

# LOGGING

Store logs

```
/var/log/thinclient/
```

Include

* boot.log
* rdp.log
* watchdog.log
* network.log
* install.log

Rotate automatically.

---

# ISO BUILDER

Create

```
./build.sh
```

Output

```
thinclient.iso
```

No manual steps.

---

# PROJECT STRUCTURE

```
thinclient/
│
├── build.sh
├── README.md
├── config/
├── scripts/
├── systemd/
├── docs/
├── assets/
├── installer/
├── docker/
├── tests/
└── iso/
```

---

# DOCKER TEST ENVIRONMENT

Create a complete Docker-based development environment so the project can be tested without repeatedly installing Debian on physical hardware.

Provide:

* Dockerfile for the thin client build environment
* docker-compose.yml
* Test scripts
* Mock configuration
* Build automation

The Docker environment should allow:

* Building the project
* Running installation scripts
* Testing configuration parsing
* Testing systemd services (where feasible)
* Testing watchdog logic
* Testing auto-reconnect scripts
* Validating FreeRDP command generation

If GUI/RDP functionality cannot be fully exercised inside a container, clearly document those limitations and provide alternative validation steps.

---

# REAL RDP SERVER TESTING

I already have a live Windows RDP server.

I will provide:

* Server IP
* Port
* Username
* Password

Design the project so these credentials are supplied via the configuration file (or environment variables for testing), **never hardcoded in source code**.

Provide a script such as:

```
./test-rdp.sh
```

that:

* Reads the configuration
* Verifies TCP connectivity
* Validates RDP authentication where possible
* Starts a test FreeRDP session
* Produces detailed logs
* Reports success or failure with actionable diagnostics

---

# DOCUMENTATION

Generate complete documentation

* Architecture
* Boot Flow
* Deployment
* Clonezilla Deployment
* Configuration
* Admin Guide
* Recovery
* Troubleshooting
* Security
* Future VPN Integration

---

# DIAGRAMS

Generate Mermaid diagrams for

* Overall Architecture
* Boot Process
* Login Flow
* RDP Flow
* Watchdog Flow
* Auto Reconnect
* Admin Mode
* Deployment Process

---

# CODE QUALITY

Requirements

* No TODOs
* No placeholders
* No pseudo code
* Fully working Bash
* Fully working systemd services
* Production-ready configuration
* Modular architecture
* Clean code
* Well documented

Think like you're building a commercial Thin Client OS similar to IGEL, HP ThinPro, Dell Wyse, or Stratodesk—but tailored for a dedicated Windows RDP workflow.
