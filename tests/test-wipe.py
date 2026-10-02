"""Remote wipe (security plan A5): everything that matters is erased, the device is
deregistered (and cannot quietly re-enrol), it locks for good — and the manager is told
the wipe was received BEFORE the credentials that acknowledgement needs are destroyed."""
import importlib.machinery, importlib.util, os, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
tmp = tempfile.mkdtemp()
os.environ["TC_LICENSE_CONF"] = conf = os.path.join(tmp, "license.conf")
os.environ["TC_LICENSE_DIR"] = os.path.join(tmp, "license")
spec = importlib.util.spec_from_loader("tcagent", importlib.machinery.SourceFileLoader(
    "tcagent", os.path.join(ROOT, "scripts", "thinclient-agent")))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

ok = 0
def check(name, cond):
    global ok
    assert cond, "FAIL " + name
    ok += 1
    print("  PASS " + name)

home = os.path.join(tmp, "home"); os.makedirs(home)
run = os.path.join(tmp, "run"); os.makedirs(run)
m._kiosk_home = lambda: home
m.RUN_DIR = run
m.REC_DIR = os.path.join(tmp, "rec"); os.makedirs(m.REC_DIR)
m.CHAT_DIR = os.path.join(tmp, "chat"); os.makedirs(m.CHAT_DIR)
m.MANAGED_RDP = os.path.join(run, "rdp-managed")
m.LEGACY_MANAGED_RDP = os.path.join(tmp, "rdp-managed-old")
m.CERT_SEEN = os.path.join(run, "cert-seen.json")
m.WIPED_MARK = os.path.join(tmp, "wiped")
m.TC_LOG_DIR = os.path.join(tmp, "log"); os.makedirs(m.TC_LOG_DIR)
locks, drops = [], []
m.set_admin_lock = lambda locked, *a, **k: locks.append((locked,) + a)
m._drop_rdp_session = lambda *a: drops.append(a)
_real_run = m.subprocess.run
m.subprocess.run = lambda *a, **k: _real_run(["true"])     # no pkill on the test machine

open(conf, "w").write("CONTROL_URL=https://example\nENROLL_CODE=abc\nDEVICE_SECRET=s3cret\nTENANT_TOKEN=tok\n")
secrets = {
    os.path.join(m.REC_DIR, "seg1.ts"): "screen", os.path.join(m.CHAT_DIR, "log.jsonl"): "chat",
    m.MANAGED_RDP: "PASSWORD_OBF=x", m.LEGACY_MANAGED_RDP: "PASSWORD_OBF=x", m.CERT_SEEN: "{}",
    os.path.join(home, ".thinclient-rdp"): "SERVER_IP=1", os.path.join(home, ".thinclient-lock"): "a:b",
    os.path.join(home, ".thinclient-lock.meta.json"): "{}", os.path.join(home, ".thinclient-lock-state.json"): "{}",
    os.path.join(run, "rdp-profile-pw-1000"): "x", os.path.join(m.TC_LOG_DIR, "rdp.log"): "/v:10.0.0.5 /u:operator1",
}
for p, d in secrets.items():
    open(p, "w").write(d)

print("== the command is acknowledged before anything is erased ==")
check("WIPE returns ok", m.execute("WIPE") == "ok")
check("…and has NOT wiped yet (the ack still needs the device secret)",
      os.path.exists(m.MANAGED_RDP) and "DEVICE_SECRET=s3cret" in open(conf).read())
check("…but the wipe is pending", m._PENDING_WIPE[0] is True)

print("== the wipe ==")
m.wipe_device()
left = [p for p in secrets if os.path.exists(p)]
check("every path the wipe touched was inside the test area",
      all(p.startswith(tmp) for p in m._wipe_paths()))
check("every secret and data file is gone", left == [])
c = open(conf).read()
check("device secret erased", "DEVICE_SECRET=\n" in c)
check("enrolment code erased", "ENROLL_CODE=\n" in c)
check("TENANT TOKEN erased — so it cannot quietly re-enrol into the fleet", "TENANT_TOKEN=\n" in c)
check("the manager address is kept (it is not a secret)", "CONTROL_URL=https://example" in c)
check("the RDP session was ended", len(drops) == 1)
check("locked PERMANENTLY, with no working-hours-looking message", (True, "permanent", 24, "") in locks)
check("the wiped marker is written for the screens to explain", os.path.exists(m.WIPED_MARK))
check("the wipe is no longer pending", m._PENDING_WIPE[0] is False)
check("enrolment now refuses: no credentials and no token",
      not (m.conf_get("ENROLL_CODE") and m.conf_get("DEVICE_SECRET")) and not m.conf_get("TENANT_TOKEN"))

print("\n  %d passed" % ok)
