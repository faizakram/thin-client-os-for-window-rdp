"""Memory hardening against the REAL grub-mkconfig (Debian trixie, amd64). Run via tests/grub/run.sh."""
import importlib.machinery, importlib.util, os, shutil, subprocess
spec = importlib.util.spec_from_loader("a", importlib.machinery.SourceFileLoader("a", "/project/scripts/thinclient-agent"))
a = importlib.util.module_from_spec(spec); spec.loader.exec_module(a)
ok = 0
def check(n, c):
    global ok
    assert c, "FAIL " + n
    ok += 1; print("  PASS " + n)
linux_lines = lambda: [l.strip() for l in open("/boot/grub/grub.cfg") if l.strip().startswith("linux")]
orig_default = open("/etc/default/grub").read()
orig_cfg = open("/boot/grub/grub.cfg").read()
print("== enable, real grub-mkconfig ==")
check("applied", a._apply_kernel_params(True) is True)
L = linux_lines()
check("there are linux boot entries (%d)" % len(L), len(L) >= 1)

check("EVERY linux entry carries all three parameters", all(all(p in l for p in a.MEM_HARDEN_PARAMS) for l in L))
check("the existing boot options survive (quiet splash ... usbcore.autosuspend=-1)",
      all("quiet splash" in l and "usbcore.autosuspend=-1" in l for l in L if "single" not in l))
check("previous grub.cfg kept as .tc-prev", open("/boot/grub/grub.cfg.tc-prev").read() == orig_cfg)
check("no staged file left", not os.path.exists("/boot/grub/grub.cfg.tc-new"))
print("   e.g.", L[0][:160])
print("== idempotent ==")
before = open("/boot/grub/grub.cfg").read()
check("enabling again changes nothing", a._apply_kernel_params(True) is True and open("/boot/grub/grub.cfg").read() == before)
print("== disable ==")
check("restored", a._apply_kernel_params(False) is True)
check("no entry carries the parameters", not any("init_on_free=1" in l or "intel_iommu" in l for l in linux_lines()))
check("/etc/default/grub is back to the installer's line",
      [l for l in open("/etc/default/grub").read().splitlines() if l.startswith("GRUB_CMDLINE_LINUX_DEFAULT")]
      == [l for l in orig_default.splitlines() if l.startswith("GRUB_CMDLINE_LINUX_DEFAULT")])
print("== grub-mkconfig FAILS midway: nothing on the boot path changes ==")
good_cfg = open("/boot/grub/grub.cfg").read(); good_def = open("/etc/default/grub").read()
os.rename("/etc/grub.d/10_linux", "/tmp/10_linux")
with open("/etc/grub.d/10_linux", "w") as f: f.write("#!/bin/sh\necho 'menuentry broken {'\nexit 1\n")
os.chmod("/etc/grub.d/10_linux", 0o755)
check("reported as not applied", a._apply_kernel_params(True) is False)
check("grub.cfg untouched", open("/boot/grub/grub.cfg").read() == good_cfg)
check("/etc/default/grub rolled back", open("/etc/default/grub").read() == good_def)
check("no staged file left", not os.path.exists("/boot/grub/grub.cfg.tc-new"))
os.replace("/tmp/10_linux", "/etc/grub.d/10_linux")
print("== grub-mkconfig 'succeeds' but drops our parameters: refused too ==")
os.makedirs("/etc/default/grub.d", exist_ok=True)
with open("/etc/default/grub.d/zz-override.cfg", "w") as f: f.write('GRUB_CMDLINE_LINUX=""\n')
check("an override that strips them is caught", a._apply_kernel_params(True) is False)
check("grub.cfg still the good one", open("/boot/grub/grub.cfg").read() == good_cfg)
os.remove("/etc/default/grub.d/zz-override.cfg")
print("== real grub-script-check accepts the generated config ==")
a._apply_kernel_params(True)
r = subprocess.run(["grub-script-check", "/boot/grub/grub.cfg"], capture_output=True, text=True)
check("grub-script-check passes (rc=%d %s)" % (r.returncode, r.stderr.strip()[:80]), r.returncode == 0)
print("\n  %d passed" % ok)
