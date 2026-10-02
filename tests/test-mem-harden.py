"""Memory hardening (security plan A3) — the first OTA change ever to touch the boot
configuration, so the failure paths get the most attention: a failed grub-mkconfig must
leave the device exactly as bootable as it was."""
import importlib.machinery, importlib.util, os, sys, tempfile, types

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
spec = importlib.util.spec_from_loader("tcagent", importlib.machinery.SourceFileLoader(
    "tcagent", os.path.join(ROOT, "scripts", "thinclient-agent")))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

ok = 0
def check(name, cond):
    global ok
    assert cond, "FAIL " + name
    ok += 1
    print("  PASS " + name)

ORIG = ('GRUB_DEFAULT=0\nGRUB_TIMEOUT=1\n'
        'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash loglevel=0 usbcore.autosuspend=-1"\n'
        'GRUB_CMDLINE_LINUX=""\n')
WORKING_CFG = "menuentry 'ThinClient' { linux /vmlinuz root=/dev/sda2 quiet splash }\n"

print("== the parameter line ==")
line = 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash usbcore.autosuspend=-1"'
on = m.cmdline_with(line, True)
check("our parameters are added", all(p in on for p in m.MEM_HARDEN_PARAMS))
check("every existing parameter is kept (the camera fix's autosuspend=-1 included)",
      "quiet splash usbcore.autosuspend=-1" in on)
check("adding twice does not duplicate", m.cmdline_with(on, True).count("init_on_free=1") == 1)
check("removing restores the original line exactly", m.cmdline_with(on, False) == line)

def sandbox():
    d = tempfile.mkdtemp()
    m.GRUB_DEFAULT = os.path.join(d, "grub")
    m.GRUB_CFG = os.path.join(d, "grub.cfg")
    m.MEM_HARDEN_STATE = os.path.join(d, "applied")
    m._FIREWIRE_CONF = os.path.join(d, "no-firewire.conf")
    open(m.GRUB_DEFAULT, "w").write(ORIG)
    open(m.GRUB_CFG, "w").write(WORKING_CFG)
    return d

calls = []
def fake_run(result):
    """grub-mkconfig stand-in: `result` is "ok", "fail" or "garbage"."""
    def run(argv, **kw):
        calls.append(argv)
        if argv[0] == "grub-mkconfig":
            out = argv[argv.index("-o") + 1]
            params = open(m.GRUB_DEFAULT).read().split('LINUX_DEFAULT="')[1].split('"')[0]
            if result == "ok":
                open(out, "w").write("menuentry 'ThinClient' { linux /vmlinuz root=/dev/sda2 %s }\n" % params)
                return types.SimpleNamespace(returncode=0, stderr="")
            if result == "garbage":
                open(out, "w").write("")              # "succeeds" but writes nothing usable
                return types.SimpleNamespace(returncode=0, stderr="")
            return types.SimpleNamespace(returncode=1, stderr="grub-probe: error")
        return types.SimpleNamespace(returncode=0, stderr="")
    return run

print("== success: hardened from the next restart ==")
d = sandbox(); m.subprocess.run = fake_run("ok")
m.apply_mem_harden(True)
cfg = open(m.GRUB_CFG).read()
check("the live grub.cfg now boots with the parameters", all(p in cfg for p in m.MEM_HARDEN_PARAMS))
check("the previous grub.cfg is kept beside it", open(m.GRUB_CFG + ".tc-prev").read() == WORKING_CFG)
check("the state is recorded", open(m.MEM_HARDEN_STATE).read().strip() == "1")
check("sleep and hibernate are masked", ["systemctl", "mask", "hibernate.target"] in calls)
check("FireWire is blocked", "firewire_ohci" in open(m._FIREWIRE_CONF).read())
calls.clear(); m.apply_mem_harden(True)
check("running again changes nothing (idempotent)", calls == [])

print("== grub-mkconfig FAILS ==")
d = sandbox(); m.subprocess.run = fake_run("fail")
m.apply_mem_harden(True)
check("THE SAFETY NET: grub.cfg is untouched — the device boots as before",
      open(m.GRUB_CFG).read() == WORKING_CFG)
check("/etc/default/grub is restored too", open(m.GRUB_DEFAULT).read() == ORIG)
check("no half-written staging file is left", not os.path.exists(m.GRUB_CFG + ".tc-new"))
check("it is NOT recorded as applied, so it will try again", not os.path.exists(m.MEM_HARDEN_STATE))

print("== grub-mkconfig 'succeeds' but writes something unusable ==")
d = sandbox(); m.subprocess.run = fake_run("garbage")
m.apply_mem_harden(True)
check("an empty config is never installed", open(m.GRUB_CFG).read() == WORKING_CFG)
check("defaults restored", open(m.GRUB_DEFAULT).read() == ORIG)

print("== turning it off again ==")
d = sandbox(); m.subprocess.run = fake_run("ok")
m.apply_mem_harden(True); m.apply_mem_harden(False)
check("parameters removed from the boot config", "init_on_free=1" not in open(m.GRUB_CFG).read())
check("the original command line is back, byte for byte", open(m.GRUB_DEFAULT).read() == ORIG)
check("sleep targets unmasked", ["systemctl", "unmask", "sleep.target"] in calls)
check("FireWire unblocked", not os.path.exists(m._FIREWIRE_CONF))

print("== never touches a device that never had it ==")
d = sandbox(); calls.clear(); m.apply_mem_harden(False)
check("policy off on a never-hardened device: nothing at all is run", calls == [])

print("== a USB-booted (live) device is left alone ==")
d = sandbox()
real_exists = os.path.exists
m.os.path.exists = lambda p: True if p == "/run/live/medium" else real_exists(p)
check("boot config untouched on live media", m._apply_kernel_params(True) is False
      and open(m.GRUB_DEFAULT).read() == ORIG)
m.os.path.exists = real_exists

print("\n  %d passed" % ok)
