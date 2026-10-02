"""Clipboard control and the USB storage block (security plan G7).

The USB block's one dangerous case gets the most care: a device that BOOTS from a USB
disk must never have USB storage blocked."""
import importlib.machinery, importlib.util, os, sys, tempfile, types

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
os.environ["TC_SEC_POLICY"] = os.path.join(tmp, "policy.json")

def load(name, path):
    spec = importlib.util.spec_from_loader(name, importlib.machinery.SourceFileLoader(name, path))
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m); return m
conn = load("tcconn", os.path.join(ROOT, "scripts", "thinclient-connect"))
agent = load("tcagent", os.path.join(ROOT, "scripts", "thinclient-agent"))
sp = conn.secpolicy()

ok = 0
def check(name, cond):
    global ok
    assert cond, "FAIL " + name
    ok += 1
    print("  PASS " + name)

fake = types.SimpleNamespace(rdp="xfreerdp3", video_choice=lambda: "auto", scale_choice=lambda: "100",
                             scr_w=1920, scr_h=1080, msg=lambda *a: None)
def argv():
    return conn.Connect.rdp_argv(fake, "10.0.0.5", "3389", "op1", "", "nla")

print("== clipboard ==")
check("no policy: clipboard shared, as today", "/clipboard" in argv() and "-clipboard" not in argv())
sp.save({"clipboard": False}, os.environ["TC_SEC_POLICY"])
check("tenant turned it off: -clipboard (verified to parse in FreeRDP 3.15.0)",
      "-clipboard" in argv() and "/clipboard" not in argv())
sp.save({"clipboard": True}, os.environ["TC_SEC_POLICY"])
check("turned back on", "/clipboard" in argv())
check("nothing else in the command line changed", argv()[:3] == ["xfreerdp3", "/v:10.0.0.5:3389", "/u:op1"])

print("== USB storage block ==")
agent._USB_BLOCK_CONF = os.path.join(tmp, "no-usb.conf")
ran = []
agent.subprocess.run = lambda a, **k: (ran.append(a), types.SimpleNamespace(returncode=0, stdout=""))[1]
real_exists = os.path.exists

agent._boot_disk_transport = lambda: "sata"
check("boot disk on SATA: blocked", agent.apply_usb_storage_block(True) == "blocked")
conf = open(agent._USB_BLOCK_CONF).read()
check("only the two USB STORAGE drivers are refused", "usb-storage" in conf and "uas" in conf)
check("SD/MMC drivers are NOT touched (eMMC boot disks)", "mmc" not in conf and "sdhci" not in conf)
check("keyboards/webcams/headsets/tethering drivers are not mentioned",
      not any(x in conf for x in ("usbhid", "uvcvideo", "snd", "rndis", "cdc", "ipheth", "qmi")))
check("the driver is unloaded now if unused", ["modprobe", "-r", "uas", "usb-storage"] in ran)
check("reported as blocked", agent._SECURITY_FACTS["usb_storage"] == "blocked")

os.remove(agent._USB_BLOCK_CONF)
agent._boot_disk_transport = lambda: "usb"
check("THE DANGER: boot disk on USB -> NOT blocked", agent.apply_usb_storage_block(True) == "skipped-usb-boot")
check("…and no block file written", not os.path.exists(agent._USB_BLOCK_CONF))
agent._boot_disk_transport = lambda: None
check("boot disk transport unknown -> treated as unsafe, not blocked",
      agent.apply_usb_storage_block(True) == "skipped-usb-boot")
agent._boot_disk_transport = lambda: "nvme"
agent.os.path.exists = lambda p: True if p == "/run/live/medium" else real_exists(p)
check("running from a live USB -> left alone", agent.apply_usb_storage_block(True) == "skipped-live")
agent.os.path.exists = real_exists

agent.apply_usb_storage_block(True)
check("turning it off removes the block", agent.apply_usb_storage_block(False) == "allowed"
      and not os.path.exists(agent._USB_BLOCK_CONF))

print("\n  %d passed" % ok)
