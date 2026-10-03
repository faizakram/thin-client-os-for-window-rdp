"""OS security updates (plan G2) and the memory-hardening extras (plan A3, part 2).

The apt work itself is tested against the real Debian security archive in
tests/ospatch/run.sh. Here: everything around it — the policy switch, the staging
decision (canary vs fleet), reporting, and the MOR / shutdown-wipe / Thunderbolt parts,
none of which may do anything at all while their switch is off.
"""
import importlib.machinery, importlib.util, json, os, struct, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
tmp = tempfile.mkdtemp()
os.environ.update(TC_OSPATCH_DIR=os.path.join(tmp, "os-update"),
                  TC_OSPATCH_UNIT=os.path.join(tmp, "units", "thinclient-os-patch.service"),
                  TC_MEMWIPE_UNIT=os.path.join(tmp, "units", "thinclient-memwipe.service"),
                  TC_EFIVARS=os.path.join(tmp, "efivars"))

def load(name, path):
    spec = importlib.util.spec_from_loader(name, importlib.machinery.SourceFileLoader(name, path))
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m); return m

agent = load("tcagent", os.path.join(ROOT, "scripts", "thinclient-agent"))
osp = load("tcospatch", os.path.join(ROOT, "scripts", "thinclient-ospatch"))
sp = load("tcsecpol", os.path.join(ROOT, "scripts", "thinclient-secpolicy"))

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
    calls.append(list(argv)); return R()
agent.subprocess.run = fake_run

print("== the policy switch: off unless the manager says on ==")
check("default off", sp.normalise({})["os_updates"] is False)
check("on when sent", sp.normalise({"os_updates": True})["os_updates"] is True)


print("== reading apt's plan ==")
sim = """NOTE: This is only a simulation!
Inst libssl3t64 [3.5.7-1~deb13u2] (3.5.7-1~deb13u3 Debian-Security:13/stable-security [amd64])
Inst linux-image-6.12.110+deb13-amd64 (6.12.110-1 Debian-Security:13/stable-security [amd64])
Conf libssl3t64 (3.5.7-1~deb13u3 Debian-Security:13/stable-security [amd64])"""
check("upgrades and NEW packages (a new kernel) both listed, as name=version",
      osp.parse_simulation(sim) == ["libssl3t64=3.5.7-1~deb13u3", "linux-image-6.12.110+deb13-amd64=6.12.110-1"])
check("a kernel needs the one restart", bool(osp.REBOOT_PKGS.match("linux-image-6.12.110+deb13-amd64")))
check("libssl does not", not osp.REBOOT_PKGS.match("libssl3t64"))
osp.cmd_stage(["openssl=3.5; rm -rf /", "../x=1", "bad"])
check("malformed specs are never staged", not os.path.exists(osp.STAGE))
osp.cmd_stage(["openssl=3.5.7-1~deb13u3"])
check("a good spec is", json.load(open(osp.STAGE))["packages"] == ["openssl=3.5.7-1~deb13u3"])

print("== switching it on / off ==")
calls.clear(); agent.apply_os_updates(True)
check("on: the boot-time unit is installed", os.path.exists(os.environ["TC_OSPATCH_UNIT"]))
unit = open(os.environ["TC_OSPATCH_UNIT"]).read()
check("…and runs BEFORE the kiosk", "Before=display-manager.service lightdm.service thinclient-x.service" in unit)
check("…and never on a live USB", "ConditionPathExists=!/run/live/medium" in unit)
check("…enabled", ["systemctl", "enable", "thinclient-os-patch.service"] in calls)
calls.clear(); agent.apply_os_updates(False)
check("off: unit removed", not os.path.exists(os.environ["TC_OSPATCH_UNIT"]))
check("off: anything staged is DISCARDED (nothing installs at the next boot)", not os.path.exists(osp.STAGE))

print("== one cycle: what gets staged ==")
seen = {}
def fake_ospatch(*args, timeout=0):
    seen.setdefault("calls", []).append(args)
    if args[0] == "check":
        return {"pending": ["libssl3t64=3.5.7-1~deb13u3", "libpcre2-8-0=10.46-1~deb13u3"], "error": None}
    if args[0] == "download":
        return {"downloaded": True, "error": None}
    if args[0] == "stage":
        seen["staged"] = list(args[1:]); return {"staged": len(args) - 1}
    return {}
posts = []
def fake_curl(url, payload):
    posts.append(payload)
    if "pending" in payload:
        return {"canary": False, "allow": ["libssl3t64=3.5.7-1~deb13u3", "evil=1.0"]}
    return {"ok": True}
agent._ospatch = fake_ospatch; agent._curl_json = fake_curl
agent.conf_get = lambda k, d="": {"CONTROL_URL": "https://m.example", "ENROLL_CODE": "E1", "DEVICE_SECRET": "S1"}.get(k, d)
agent._OSPATCH_ON[0] = False
agent.os_patch_cycle()
check("switched off: no check, no download, nothing staged", "calls" not in seen)
agent._OSPATCH_ON[0] = True
agent.os_patch_cycle()
check("fleet device: only what the manager APPROVED is staged", seen["staged"] == ["libssl3t64=3.5.7-1~deb13u3"])
check("…and never something it didn't ask about", "evil=1.0" not in seen["staged"])
check("the manager is asked with the device's own credentials", posts[-1]["enroll_code"] == "E1")

print("== the last boot's install is reported once ==")
os.makedirs(agent.OSPATCH_DIR, exist_ok=True)
json.dump({"applied_at": 1, "result": "ok", "installed": ["libssl3t64=3.5.7-1~deb13u3"], "error": None,
           "reported": False}, open(os.path.join(agent.OSPATCH_DIR, "result.json"), "w"))
posts.clear(); agent.os_patch_cycle()
check("reported", any("applied" in p and p["applied"]["result"] == "ok" for p in posts))
posts.clear(); agent.os_patch_cycle()
check("…only once", not any("applied" in p for p in posts))
rep = agent._os_updates_report()["os_updates"]
check("security report carries it", rep["enabled"] is True and rep["result"] == "ok" and rep["installed"] == 1)

print("== MOR: the firmware's own RAM wipe ==")
check("no variable on this firmware -> unsupported, nothing written", agent.apply_mor(True) == "unsupported")
os.makedirs(os.environ["TC_EFIVARS"], exist_ok=True)
mor = os.path.join(os.environ["TC_EFIVARS"], agent.MOR_VAR)
open(mor, "wb").write(struct.pack("<I", 7) + b"\x00")
calls.clear()
check("set", agent.apply_mor(True) == "set")
check("…written as attributes 0x7 + value 1", open(mor, "rb").read() == struct.pack("<I", 7) + b"\x01")
check("…immutable flag lifted and restored", ["chattr", "-i", mor] in calls and ["chattr", "+i", mor] in calls)
calls.clear()
check("already set: nothing written", agent.apply_mor(True) == "set" and not calls)
check("cleared when switched off", agent.apply_mor(False) == "cleared" and open(mor, "rb").read()[4] == 0)

print("== shutdown wipe ==")
calls.clear(); agent.apply_memwipe_unit(True)
body = open(os.environ["TC_MEMWIPE_UNIT"]).read()
check("installed and enabled", ["systemctl", "enable", "--now", "thinclient-memwipe.service"] in calls)
check("drops cached file data and empties swap at shutdown", "drop_caches" in body and "swapoff" in body and "ExecStop=" in body)
calls.clear(); agent.apply_memwipe_unit(False)
check("removed when off", not os.path.exists(os.environ["TC_MEMWIPE_UNIT"]))
check("…WITHOUT running the wipe on a live machine (no --now)",
      ["systemctl", "disable", "thinclient-memwipe.service"] in calls and not any("--now" in c for c in calls))

print("== Thunderbolt: reported ==")
r = tempfile.mkdtemp()
check("no controller", agent.thunderbolt_facts(r) == {"present": False})
d = os.path.join(r, "sys/bus/thunderbolt/devices/domain0"); os.makedirs(d)
open(os.path.join(d, "security"), "w").write("user\n"); open(os.path.join(d, "iommu_dma_protection"), "w").write("1\n")
check("level and DMA protection read", agent.thunderbolt_facts(r) == {"present": True, "security": "user", "dma_protection": True})

print("\n  %d passed" % ok)
