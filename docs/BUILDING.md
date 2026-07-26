# Building the ISO

The build is **multi-arch aware** but the deployable image for typical thin
clients is **amd64 (x86_64)**. Where you build matters.

## TL;DR

| You are on… | Do this | Produces |
|---|---|---|
| **amd64 Linux** (Debian/Ubuntu, cloud VM, spare PC, WSL2/x86) | `./bootstrap-build-host.sh` | ✅ deployable **amd64** ISO (fast, native) |
| **amd64 Linux** (deps already installed) | `sudo ./build.sh` or `make iso` | ✅ deployable **amd64** ISO (fast, native) |
| **Apple Silicon Mac / arm64 (Docker)** | `make iso` | ✅ deployable **amd64** ISO (works, slower under emulation) |
| **Apple Silicon Mac** (native, for a quick pipeline check) | `make iso-native` | ⚠️ **arm64** ISO (won't boot x86 PCs) |

> **Verified:** the default `make iso` (amd64) completes on an Apple Silicon Mac
> and produces a bootable BIOS+UEFI `thinclient.iso`. It just runs the amd64
> userland under Docker's emulation, so it is slower than a native amd64 host.

## The one build gotcha: never build on the bind mount

live-build creates a full Linux root filesystem (device nodes, hardlinks,
xattrs, precise ownership). That **cannot** be created on a macOS-backed bind
mount (VirtioFS) — debootstrap fails with:

```
E: Tried to extract package, but tar failed.
E: An unexpected failure occurred, exiting...
```

This is **not** an architecture problem (it happens on native arm64 too). The
fix is already built in: the Docker builder writes the rootfs to the **`tc-build`
Docker volume** (a real Linux ext4 fs inside the VM) via `TC_BUILD_DIR=/build`,
and only the finished ISO is copied back to the bind-mounted `iso/`. If you run
`build.sh` directly (not via Docker) on a Linux host, the default
`build/live-build` is already a real Linux fs, so nothing special is needed.

## On this Apple Silicon Mac (Docker)

```bash
make iso           # builds the deployable amd64 ISO under emulation
```
Slower than native (emulated amd64 userland) but it works end-to-end and
produces `iso/thinclient.iso`. This was used to build and verify the shipped
image.

## Faster: build on an amd64 Linux host

For quicker rebuilds, any x86_64 Debian 12/13 or Ubuntu 22.04+ machine works —
including a $5/month cloud VM, a spare PC, a CI runner, or WSL2 on an x86 Windows
laptop.

```bash
# Copy this repo to the host, then:
./bootstrap-build-host.sh          # installs live-build + builds
#   or, if the toolchain is already present:
sudo ./build.sh
```

Output:
```
iso/thinclient.iso
iso/thinclient.iso.sha256
```

Native build time is roughly **15–30 minutes** on a 4-core box with a decent
connection (mostly downloading packages, cached on rebuilds).

### Using Docker on an amd64 Linux host
```bash
make iso        # runs the privileged builder; native, fast
```

## Local validation on Apple Silicon (arm64 proof build)

To validate the entire pipeline end-to-end on your Mac — the customization hook,
package resolution, service enablement, and ISO assembly — build a **native
arm64** image:

```bash
make iso-native      # TC_PLATFORM=linux/arm64 TC_ARCH=arm64
```

This runs natively (no emulation, no `tar` failure) and produces a bootable
arm64 `iso/thinclient.iso`. It proves the build is correct; it just targets ARM,
so it won't run on x86 thin clients. When the same code builds cleanly on an
amd64 host, you get the deployable image.

## Build knobs (environment variables)

| Var | Default | Purpose |
|---|---|---|
| `TC_ARCH` | `amd64` | Target architecture (`amd64`, `arm64`, `i386`) |
| `TC_DIST` | `trixie` | Debian suite |
| `TC_MIRROR` | `http://deb.debian.org/debian/` | Package mirror |
| `TC_VERSION` | `1.0.0` | Stamped into `/etc/thinclient/build-info` and the ISO label |
| `TC_PLATFORM` | `linux/amd64` | Docker builder platform (compose only) |

## What the build does (high level)

1. `lb config` — lays out the live-build tree for `TC_ARCH`, selects the
   BIOS+UEFI hybrid ISO (amd64) or UEFI ISO (arm64), and the archive areas
   including `non-free-firmware`.
2. Stages every appliance file into `config/includes.chroot` at its target path.
3. Copies the arch-aware package lists and the customization hook.
4. `lb build` — debootstraps the base, installs packages, runs the hook
   (creates the locked user, enables services, hardens, sets Plymouth), then
   assembles the ISO.
5. Copies the result to `iso/thinclient.iso` and writes a `.sha256`.

See [DEPLOYMENT.md](DEPLOYMENT.md) for what to do with the ISO.
