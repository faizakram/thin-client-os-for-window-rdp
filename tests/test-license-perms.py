"""The device secret must not be readable by the operator account (security follow-up).

license.conf holds DEVICE_SECRET and the fleet enrolment token. It used to be 0644
because the connect screen (running as the operator) read LICENSE_ENFORCE from it, so
anyone at the keyboard with a shell could copy the secret and impersonate the device.
"""
import importlib.machinery, importlib.util, os, stat, sys, tempfile, types

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

class _Any(type):
    def __getattr__(cls, name):
        return _Any(name, (object,), {})
gi = types.ModuleType("gi"); gi.require_version = lambda *a: None
repo = types.ModuleType("gi.repository")
for n in ("Gtk", "GLib", "Gdk", "Pango", "GdkPixbuf"):
    setattr(repo, n, _Any(n, (object,), {}))
sys.modules.update({"gi": gi, "gi.repository": repo})

tmp = tempfile.mkdtemp()
CONF = os.path.join(tmp, "etc", "license.conf")
PUB = os.path.join(tmp, "lic", "public.conf")
os.makedirs(os.path.dirname(CONF))
os.environ.update(TC_LICENSE_CONF=CONF, TC_LICENSE_PUBLIC=PUB,
                  TC_LICENSE_DIR=os.path.join(tmp, "lic"),
                  TC_LICENSE_STATE=os.path.join(tmp, "lic", "state"),
                  TC_LICENSE_ADMIN_LOCK=os.path.join(tmp, "lic", "admin-lock"))

def load(name, path):
    spec = importlib.util.spec_from_loader(name, importlib.machinery.SourceFileLoader(name, path))
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m); return m

agent = load("tcagent", os.path.join(ROOT, "scripts", "thinclient-agent"))
conn = load("tcconn", os.path.join(ROOT, "scripts", "thinclient-connect"))

ok = 0
def check(name, cond):
    global ok
    assert cond, "FAIL " + name
    ok += 1
    print("  PASS " + name)
mode = lambda p: stat.S_IMODE(os.stat(p).st_mode)

SECRET = "s3cr3t-device-value"
with open(CONF, "w") as f:
    f.write("CONTROL_URL=https://example.invalid\nLICENSE_ENFORCE=true\nENROLL_CODE=abc\n"
            "DEVICE_SECRET=%s\nTENANT_TOKEN=tok-xyz\n" % SECRET)
os.chmod(CONF, 0o644)                 # as an older install or the installer left it

print("== the agent locks it down ==")
check("the agent still reads its secret", agent.conf_get("DEVICE_SECRET") == SECRET)
check("license.conf is now root-only (0600)", mode(CONF) == 0o600)
check("the public copy exists and is world-readable", mode(PUB) == 0o644)
pub = open(PUB).read()
check("the public copy carries LICENSE_ENFORCE", pub.strip() == "LICENSE_ENFORCE=true")
check("…and NO secret, code or token", SECRET not in pub and "tok-xyz" not in pub and "abc" not in pub)

print("== writes keep it root-only ==")
agent._set_conf_key("DEVICE_SECRET", "rotated-value")
check("a rotated secret is written 0600", mode(CONF) == 0o600)
check("…and read back", agent.conf_get("DEVICE_SECRET") == "rotated-value")
os.chmod(CONF, 0o644); os.utime(CONF, (1, 1))   # someone rewrote it world-readable
agent.conf_get("ENROLL_CODE")
check("a rewrite by anything else is re-protected on the next read", mode(CONF) == 0o600)

print("== the connect screen still sees the licence switch ==")
open(os.environ["TC_LICENSE_STATE"], "w").write("state=locked\n")
check("enforce=true from the public copy -> licence block shown",
      conn.license_block_reason() is not None)
open(PUB, "w").write("LICENSE_ENFORCE=false\n")
check("enforce=false in the public copy -> no block", conn.license_block_reason() is None)
os.remove(PUB)
check("no public copy yet (older agent): falls back to license.conf as before",
      conn.license_block_reason() is not None)

print("\n  %d passed" % ok)
