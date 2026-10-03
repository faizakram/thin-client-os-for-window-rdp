"""The device security report (plan item A1) and its one non-negotiable property:
a failure while gathering it must never break the poll — a reporting bug must not
cost a device its link to the manager."""
import importlib.machinery, importlib.util, os, sys, tempfile

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

def fake_root(cpu_flags, klog, tpm=None, secure_boot=None, cmdline="quiet", iommu=False, live=False):
    r = tempfile.mkdtemp()
    def w(path, data, mode="w"):
        os.makedirs(os.path.dirname(r + path), exist_ok=True)
        with open(r + path, mode) as f:
            f.write(data)
    w("/proc/cpuinfo", "model name\t: Test CPU 9000\nflags\t\t: fpu %s\n" % cpu_flags)
    w("/klog", klog)
    w("/proc/cmdline", cmdline)
    if tpm:
        w("/sys/class/tpm/tpm0/tpm_version_major", tpm)
    if secure_boot is not None:
        w("/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-e0f84a3cb4bd",
          bytes([6, 0, 0, 0, 1 if secure_boot else 0]), "wb")
    if iommu:
        w("/sys/class/iommu/dmar0/x", "")
    if live:
        os.makedirs(r + "/run/live/medium")
    return r

print("== a fully capable, fully protected machine ==")
f = m.gather_hardware_facts(fake_root("sse tme", "x86/tme: enabled by BIOS\ntpm_crb MSFT0101:00\n",
                                      tpm="2", secure_boot=True,
                                      cmdline="init_on_free=1 init_on_alloc=1", iommu=True))
check("CPU model read", f["cpu_model"] == "Test CPU 9000")
check("memory encryption: supported AND active", f["mem_enc_supported"] and f["mem_enc_active"])
check("TPM 2.0 on a firmware (CRB) interface", f["tpm"] == {"present": True, "version": "2", "interface": "crb"})
check("Secure Boot on", f["secure_boot"] is True)
check("kernel memory hardening detected", f["kernel_hardening"] is True)
check("IOMMU active", f["iommu_active"] is True)

print("== an older machine: nothing available ==")
f = m.gather_hardware_facts(fake_root("sse", "", secure_boot=False))
check("memory encryption not supported", f["mem_enc_supported"] is False and f["mem_enc_active"] is False)
check("no TPM", f["tpm"] == {"present": False})
check("Secure Boot off", f["secure_boot"] is False)
check("not hardened", f["kernel_hardening"] is False and f["iommu_active"] is False)
f = m.gather_hardware_facts(fake_root("fpu", "DMAR: IOMMU enabled\niommu: Default domain type: Translated\n"))
check("IOMMU on per the kernel log even with an empty /sys/class/iommu (Intel N5000)", f["iommu_active"] is True)
f = m.gather_hardware_facts(fake_root("fpu", "secureboot: Secure boot enabled\n", secure_boot=False))
check("Secure Boot: the kernel's 'enabled' wins over a variable read as off (encrypted machine)", f["secure_boot"] is True)
f = m.gather_hardware_facts(fake_root("fpu", "secureboot: Secure boot disabled\n", secure_boot=True))
check("…and its 'disabled' wins too", f["secure_boot"] is False)
f = m.gather_hardware_facts(fake_root("fpu", "iommu: Default domain type: Passthrough\n"))
check("passthrough (no translation) is NOT counted as active", f["iommu_active"] is False)

print("== supported but switched off in the BIOS ==")
f = m.gather_hardware_facts(fake_root("sme", "tpm_tis MSFT0101:00\n", tpm="2"))
check("AMD SME supported but not active is told apart from 'not supported'",
      f["mem_enc_supported"] is True and f["mem_enc_active"] is False)
check("a discrete (TIS) TPM is identified", f["tpm"]["interface"] == "tis")
check("legacy BIOS boot: Secure Boot is unknown (None), not 'off'", f["uefi"] is False and f["secure_boot"] is None)

print("== running from a USB stick ==")
check("live medium detected", m.gather_hardware_facts(fake_root("", "", live=True))["live_medium"] is True)

print("== the report can never break the poll ==")
m._HW_FACTS.clear(); m._HW_FACTS.update({"cpu_model": "X"})
m._SECURITY_FACTS.clear(); m._SECURITY_FACTS.update({"debug_access": "none"})
rep = m._security_report()
check("report combines enforcement facts and hardware", rep["debug_access"] == "none" and rep["hardware"]["cpu_model"] == "X")
def boom():
    raise RuntimeError("simulated bug")
m._lockout_report = boom
rep = m._security_report()
check("a part that throws is left out, not fatal", rep["hardware"]["cpu_model"] == "X")
m._hardware_facts = boom
check("even with two parts failing, the report still returns", isinstance(m._security_report(), dict))

print("\n  %d passed" % ok)
