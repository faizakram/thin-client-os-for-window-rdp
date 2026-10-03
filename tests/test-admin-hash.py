"""Admin Mode password set from the manager (security follow-up).

Every device shipped with the same Admin Mode password, published with the source.
The manager now sends the account's own password as a SHA-512 crypt hash; the agent
must install exactly that — and nothing it can't vouch for — without touching the rest
of admin.conf, and leave a device alone when the manager sends nothing.
"""
import importlib.machinery, importlib.util, os, stat, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
tmp = tempfile.mkdtemp()
CONF = os.path.join(tmp, "admin.conf")
os.environ["TC_ADMIN_CONF"] = CONF

spec = importlib.util.spec_from_loader("tcagent", importlib.machinery.SourceFileLoader(
    "tcagent", os.path.join(ROOT, "scripts", "thinclient-agent")))
agent = importlib.util.module_from_spec(spec); spec.loader.exec_module(agent)

ok = 0
def check(name, cond):
    global ok
    assert cond, "FAIL " + name
    ok += 1
    print("  PASS " + name)

with open(os.path.join(ROOT, "config", "admin.conf")) as f:
    factory = f.read()
with open(CONF, "w") as f:
    f.write(factory)
os.chmod(CONF, 0o600)

MGR = ("$6$rounds=200000$abcdefgh$LAoWissqmBviGGtmvhh33m3MI1AfMMQHAECnFb9znI067jygZFqUd6pe"
       ".wRlo//vcWImERwkjPfr1l5tPjbsY0")

print("== nothing from the manager: the device is left exactly as it is ==")
for nothing in (None, "", 0, {}):
    agent._apply_admin_hash(nothing)
check("admin.conf unchanged", open(CONF).read() == factory)
r = agent._admin_password_report()
check("still reported as the factory password", r["admin_password_default"] is True
      and r["admin_password_managed"] is False)

print("== anything that is not a SHA-512 crypt hash is refused ==")
for bad in ("changeme", "$1$abc$def", "$6$salt$short", MGR + "\nADMIN_HOTKEY=x",
            MGR.replace("$abcdefgh$", "$abc def$"), "$6$rounds=200000$abcdefgh$" + "!" * 86):
    check("refused: %r" % bad[:30], agent._apply_admin_hash(bad) is False)
check("…and admin.conf is untouched", open(CONF).read() == factory)

print("== the manager's hash is installed ==")
check("applied", agent._apply_admin_hash(MGR) is True)
body = open(CONF).read()
check("the hash line is replaced", "ADMIN_PASSWORD_HASH=%s\n" % MGR in body)
check("exactly one hash line", body.count("ADMIN_PASSWORD_HASH=") == 1)
check("every other setting kept",
      [l for l in body.splitlines() if not l.startswith("ADMIN_PASSWORD_HASH=")]
      == [l for l in factory.splitlines() if not l.startswith("ADMIN_PASSWORD_HASH=")])
check("still root-only (0600)", stat.S_IMODE(os.stat(CONF).st_mode) == 0o600)
check("no temp file left behind", not os.path.exists(CONF + ".tc-new"))
r = agent._admin_password_report()
check("reported: not the factory password, set by the manager",
      r["admin_password_default"] is False and r["admin_password_managed"] is True)
mtime = os.stat(CONF).st_mtime_ns
check("the same hash again is a no-op (no rewrite every poll)",
      agent._apply_admin_hash(MGR) is False and os.stat(CONF).st_mtime_ns == mtime)

print("== the real Admin Mode check accepts it ==")
env = dict(os.environ, TC_LIB_DIR=os.path.join(ROOT, "scripts", "lib"), TC_LOG_DIR=tmp,
           TC_RUN_DIR=tempfile.mkdtemp(), TC_CONF=os.path.join(ROOT, "tests", "mock", "server.conf"))
run = lambda pw: subprocess.run(["bash", os.path.join(ROOT, "scripts", "thinclient-adminctl"), "check"],
                                input=pw, capture_output=True, text=True, env=env).stdout.strip()
check("the account's password opens Admin Mode", run("Pw-Test-1") == "OK")
env["TC_RUN_DIR"] = tempfile.mkdtemp()
check("the factory password no longer does", run("changeme") == "FAIL")

print("\n  %d passed" % ok)
