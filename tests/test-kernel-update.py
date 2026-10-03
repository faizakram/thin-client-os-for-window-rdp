"""Kernel updates on encrypted machines (security plan Phase B, M5): thinclient-kernel.

Everything here runs against a fake boot partition and module tree. The boot chain
itself (systemd-boot tries, falling back to the previous image, tc-boot-bless) is
proven in the Secure Boot + TPM VM rig.
"""
import hashlib, importlib.machinery, importlib.util, json, os, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
tmp = tempfile.mkdtemp()
ESP, MODS, ST = (os.path.join(tmp, d) for d in ("esp", "modules", "state"))
GEN = os.path.join(tmp, "install-generation")
os.environ.update(TC_ESP=ESP, TC_MODULES_DIR=MODS, TC_KERNEL_DIR=ST, TC_INSTALL_GEN=GEN,
                  TC_UNAME="6.12.111+deb13-amd64", TC_KERNEL_NOREBOOT="1")
spec = importlib.util.spec_from_loader("tck", importlib.machinery.SourceFileLoader(
    "tck", os.path.join(ROOT, "scripts", "thinclient-kernel")))
k = importlib.util.module_from_spec(spec); spec.loader.exec_module(k)

ok = 0
def check(name, cond):
    global ok
    assert cond, "FAIL " + name
    ok += 1
    print("  PASS " + name)

calls = []
class R:
    def __init__(self, rc=0, out="", err=""): self.returncode, self.stdout, self.stderr = rc, out, err
def fake_run(argv, **kw):
    calls.append(list(argv))
    if argv[0] == "curl":                       # "download": copy from our fake server dir
        src = os.path.join(tmp, "server", argv[-1].rsplit("/", 1)[-1])
        dst = argv[argv.index("-o") + 1]
        if not os.path.exists(src):
            return R(22, "", "404")
        open(dst, "wb").write(open(src, "rb").read())
    return R()
k.subprocess.run = fake_run
def fake_unpack(pkg, kver):
    os.makedirs(os.path.join(MODS, kver, "kernel"), exist_ok=True)
    open(os.path.join(MODS, kver, "modules.dep"), "w").write("x")
k._unpack_modules = fake_unpack

LINUX = os.path.join(ESP, "EFI", "Linux"); os.makedirs(LINUX)
os.makedirs(os.path.join(MODS, "6.12.111+deb13-amd64"))
open(os.path.join(LINUX, "thinclient-6.12.111+deb13-amd64.efi"), "w").write("good")
os.makedirs(os.path.join(tmp, "server"))
img, pkg = b"signed-image-6.12.120", b"debian-package-6.12.120"
open(os.path.join(tmp, "server", "thinclient-6.12.120.efi"), "wb").write(img)
open(os.path.join(tmp, "server", "linux-image-6.12.120.deb"), "wb").write(pkg)
sha = lambda b: hashlib.sha256(b).hexdigest()
def manifest(kver="6.12.120+deb13-amd64", img_sha=None, **extra):
    p = os.path.join(tmp, "manifest")
    lines = ["version=1.0.170", "kernel_version=" + kver,
             "kernel_image=thinclient-6.12.120.efi", "kernel_image_sha256=" + (img_sha or sha(img)),
             "kernel_pkg=linux-image-6.12.120.deb", "kernel_pkg_sha256=" + sha(pkg)]
    lines += ["%s=%s" % kv for kv in extra.items()]
    open(p, "w").write("\n".join(lines) + "\n")
    return p
URL = "https://example.invalid/releases/latest/download"

print("== offer: only encrypted machines, only a newer kernel, only what the signed manifest names ==")
check("a plain machine is never offered a kernel", k.cmd_offer(manifest(), URL) == 0 and not os.path.exists(k.STAGED))
open(GEN, "w").write("encrypted=1\n")
k.cmd_offer(manifest(img_sha="0" * 64), URL)
check("an image that does not match the manifest hash is refused (and deleted)",
      not os.path.exists(k.STAGED) and not os.path.exists(os.path.join(ST, "dl", "6.12.120+deb13-amd64", "image.efi")))
check("...and the failure is recorded for the agent", json.load(open(k.RESULT))["result"] == "download-failed")
k.cmd_offer(manifest(kver="6.12.100+deb13-amd64"), URL)
check("an OLDER kernel is not offered", not os.path.exists(k.STAGED))
k.cmd_offer(manifest(kver="6.12.111+deb13-amd64"), URL)
check("the running kernel is not offered again", not os.path.exists(k.STAGED))
k.cmd_offer(manifest(kver="6.12.120; rm -rf /"), URL)
check("a malformed version is refused", not os.path.exists(k.STAGED))
calls.clear(); k.cmd_offer(manifest(), URL)
st = json.load(open(k.STAGED))
check("a newer kernel matching the manifest is staged", st["kver"] == "6.12.120+deb13-amd64")
check("downloaded from the update server, bandwidth-limited",
      any(c[0] == "curl" and c[-1] == URL + "/thinclient-6.12.120.efi" and "--limit-rate" in c for c in calls))
check("staging installs nothing yet", [i["file"] for i in k.images()] == ["thinclient-6.12.111+deb13-amd64.efi"])

print("== apply (boot time): modules, then the image with two tries, then one restart ==")
calls.clear(); k.TC_NOREBOOT = False
k.NO_REBOOT = False
k.cmd_apply()
check("modules unpacked for the new kernel", os.path.exists(os.path.join(MODS, "6.12.120+deb13-amd64", "modules.dep")))
check("image on the boot partition with two tries",
      sorted(i["file"] for i in k.images()) == ["thinclient-6.12.111+deb13-amd64.efi", "thinclient-6.12.120+deb13-amd64+2.efi"])
check("restarts once", ["systemctl", "reboot"] in calls)
check("staged work is consumed (never retried every boot)", not os.path.exists(k.STAGED))
check("recorded as trying", json.load(open(k.TRYING))["kver"] == "6.12.120+deb13-amd64")
check("an apply with nothing staged is a fast no-op", k.cmd_apply() == 0)

print("== settle: a new kernel that ran out of tries is removed, never offered again ==")
os.rename(os.path.join(LINUX, "thinclient-6.12.120+deb13-amd64+2.efi"), os.path.join(LINUX, "thinclient-6.12.120+deb13-amd64+0-2.efi"))
k.cmd_settle()          # still running 6.12.111: systemd-boot fell back
check("the failed image is deleted", [i["file"] for i in k.images()] == ["thinclient-6.12.111+deb13-amd64.efi"])
check("its modules are removed (we unpacked them)", not os.path.exists(os.path.join(MODS, "6.12.120+deb13-amd64")))
check("the running kernel's modules are untouched", os.path.exists(os.path.join(MODS, "6.12.111+deb13-amd64")))
check("reported as failed", json.load(open(k.RESULT))["result"] == "failed")
k.cmd_offer(manifest(), URL)
check("a kernel that failed here is never offered again", not os.path.exists(k.STAGED))

print("== settle: a mid-try state (one try used, not yet confirmed) is left alone ==")
os.remove(k.FAILED)
k.cmd_offer(manifest(), URL); k.NO_REBOOT = True; k.cmd_apply()
os.rename(os.path.join(LINUX, "thinclient-6.12.120+deb13-amd64+2.efi"), os.path.join(LINUX, "thinclient-6.12.120+deb13-amd64+1-1.efi"))
os.environ["TC_UNAME"] = "6.12.120+deb13-amd64"
k.cmd_settle()
check("not confirmed yet: nothing removed, still trying",
      len(k.images()) == 2 and os.path.exists(k.TRYING))

print("== settle: confirmed good (tc-boot-bless renamed it) -> kept, old one kept as the fallback ==")
os.rename(os.path.join(LINUX, "thinclient-6.12.120+deb13-amd64+1-1.efi"), os.path.join(LINUX, "thinclient-6.12.120+deb13-amd64.efi"))
k.cmd_settle()
check("reported ok", json.load(open(k.RESULT))["result"] == "ok" and not os.path.exists(k.TRYING))
check("both images kept (new + previous good as fallback)", len(k.images()) == 2)

print("== a third kernel: the oldest good one is pruned, never the running one or the fallback ==")
os.makedirs(os.path.join(MODS, "6.12.130+deb13-amd64"))
open(os.path.join(LINUX, "thinclient-6.12.130+deb13-amd64.efi"), "w").write("good")
k._write(k.OURS, ["6.12.120+deb13-amd64", "6.12.130+deb13-amd64"])
os.environ["TC_UNAME"] = "6.12.130+deb13-amd64"
k.cmd_settle()
check("running 130 + newest other good (120) kept, 111 pruned",
      sorted(i["kver"] for i in k.images()) == ["6.12.120+deb13-amd64", "6.12.130+deb13-amd64"])
check("modules of the ORIGINAL kernel are dpkg's, never deleted by us",
      os.path.exists(os.path.join(MODS, "6.12.111+deb13-amd64")))
os.environ["TC_UNAME"] = "6.12.111+deb13-amd64"
open(os.path.join(LINUX, "thinclient-6.12.111+deb13-amd64.efi"), "w").write("good")
k.cmd_settle()
check("the image the machine is RUNNING is never pruned, even if it is the oldest",
      any(i["kver"] == "6.12.111+deb13-amd64" for i in k.images()))

print("\n  %d passed" % ok)
