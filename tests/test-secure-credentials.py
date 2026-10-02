"""The Windows password must never be written to disk (security plan item A2).

It used to sit in /var/lib/thinclient/rdp-managed and ~/.thinclient-rdp, "protected"
by XOR with a key derived from /etc/machine-id — on the same disk. These tests read
the files back as an attacker with the disk would, and look for the password.
"""
import importlib.machinery, importlib.util, os, sys, tempfile, types

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

class _Any(type):
    """Stand-in for GTK: any attribute is another stand-in class, so module-level
    class definitions (class X(Gtk.Window)) still load without a display."""
    def __getattr__(cls, name):
        return _Any(name, (object,), {})
gi = types.ModuleType("gi"); gi.require_version = lambda *a: None
repo = types.ModuleType("gi.repository")
for n in ("Gtk", "GLib", "Gdk", "Pango", "GdkPixbuf"):
    setattr(repo, n, _Any(n, (object,), {}))
sys.modules.update({"gi": gi, "gi.repository": repo})

tmp = tempfile.mkdtemp()
os.environ["TC_RDP_PROFILE"] = os.path.join(tmp, "home", ".thinclient-rdp")
os.environ["TC_RDP_PROFILE_PW"] = os.path.join(tmp, "run", "rdp-profile-pw")
os.environ["TC_MANAGED_RDP"] = os.path.join(tmp, "run", "rdp-managed")
os.makedirs(os.path.join(tmp, "home"))

def load(name, path):
    spec = importlib.util.spec_from_loader(name, importlib.machinery.SourceFileLoader(name, path))
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m); return m

conn = load("tcconn", os.path.join(ROOT, "scripts", "thinclient-connect"))
agent = load("tcagent", os.path.join(ROOT, "scripts", "thinclient-agent"))

ok = 0
def check(name, cond):
    global ok
    assert cond, "FAIL " + name
    ok += 1
    print("  PASS " + name)

PW = "Winter-Pass-2026!"
def disk_has_password():
    """Search everything under the fake home (the disk) for the password, in clear
    AND in the old obfuscated form an attacker can reverse."""
    needles = [PW, conn._obfuscate(PW)]
    for dp, _, fs in os.walk(os.path.join(tmp, "home")):
        for f in fs:
            data = open(os.path.join(dp, f)).read()
            if any(n in data for n in needles):
                return True
    return False

print("== operator-typed password ==")
conn.save_profile("10.0.0.5", "3389", "operator1", PW, "CORP")
check("the profile on disk keeps host/user/port/domain", conn.profile_get("USERNAME") == "operator1")
check("THE FIX: the password is NOT on disk, in any form", not disk_has_password())
check("it is in RAM, so the form still pre-fills until restart", conn.saved_password() == PW)
check("the RAM copy is private to the kiosk user (0600)",
      oct(os.stat(os.environ["TC_RDP_PROFILE_PW"]).st_mode & 0o777) == "0o600")

print("== updating a device that saved a password the OLD way ==")
os.remove(os.environ["TC_RDP_PROFILE_PW"])
with open(os.environ["TC_RDP_PROFILE"], "w") as f:
    f.write("SERVER_IP=10.0.0.5\nPORT=3389\nUSERNAME=operator1\nDOMAIN=CORP\n"
            "PASSWORD_OBF=%s\n" % conn._obfuscate(PW))
check("before: the old file has the password (the vulnerability)", disk_has_password())
check("after update the operator still gets their saved password", conn.saved_password() == PW)
check("…and it has been moved OFF the disk", not disk_has_password())
check("the rest of the profile survived the move", conn.profile_get("SERVER_IP") == "10.0.0.5")

print("== manager-managed password (all 30 fleet devices) ==")
agent.MANAGED_RDP = os.environ["TC_MANAGED_RDP"]
agent._apply_managed_rdp({"host": "10.0.0.5", "user": "operator1", "password": PW})
check("the agent writes the managed profile under /run (RAM)",
      os.path.exists(agent.MANAGED_RDP) and "/run" in agent.MANAGED_RDP)
check("the connect window reads it back", conn.managed_rdp()["pw"] == PW)
check("the agent's real default path is in RAM (/run/thinclient)",
      load("tcagent2", os.path.join(ROOT, "scripts", "thinclient-agent")).MANAGED_RDP.startswith("/run/"))
check("the connect window's real default path is in RAM too",
      "/run/" in open(os.path.join(ROOT, "scripts", "thinclient-connect")).read().split("TC_MANAGED_RDP")[1][:40])

print("== the old on-disk copy is purged at agent start ==")
legacy = os.path.join(tmp, "home", "rdp-managed")
open(legacy, "w").write("PASSWORD_OBF=%s\n" % conn._obfuscate(PW))
agent.LEGACY_MANAGED_RDP = legacy
agent._purge_disk_credentials()
check("the legacy file is deleted", not os.path.exists(legacy))
check("nothing on disk holds the password afterwards", not disk_has_password())

print("\n  %d passed" % ok)
