"""Screenshot the real lock screen in admin-wait. The last bug was invisible to
assertions about objects but obvious the moment you look at the screen."""
import importlib.machinery, importlib.util, json, os, sys, tempfile
import gi
gi.require_version("Gtk", "3.0")
from gi.repository import Gtk, Gdk, GLib

tmp = tempfile.mkdtemp()
admin = os.path.join(tmp, "admin-lock")
open(admin, "w").write("0\npermanent\n0\n")
os.environ["TC_LICENSE_ADMIN_LOCK"] = admin
spec = importlib.util.spec_from_loader(
    "tclock", importlib.machinery.SourceFileLoader("tclock", os.environ.get("TC_LOCK_SRC", "/src/scripts/thinclient-lock")))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.CHAT_LOG = os.path.join(tmp, "log.jsonl"); m.CHAT_OUTBOX = os.path.join(tmp, "ob")
m.CHAT_ACTIVE = os.path.join(tmp, "ca"); m.CHAT_UNREAD = os.path.join(tmp, "cu")
open(m.CHAT_UNREAD, "w").write("2")
with open(m.CHAT_LOG, "w") as f:
    f.write(json.dumps({"sender": "admin", "body": "Locked you for a quick review - ping me when you are at your desk"}) + "\n")

OUT = os.environ.get("SHOT", "/out/lock.png")
OPEN_PANE = os.environ.get("PANE") == "1"

def grab():
    win = next((w for w in Gtk.Window.list_toplevels()
                if w.__class__.__name__ == "LockScreen"), None)
    if OPEN_PANE:
        win._open_msg()
    def snap():
        gw = win.get_window()
        pb = Gdk.pixbuf_get_from_window(gw, 0, 0, gw.get_width(), gw.get_height())
        pb.savev(OUT, "png", [], [])
        print("saved", OUT, gw.get_width(), "x", gw.get_height())
        Gtk.main_quit()
        return False
    GLib.timeout_add(500, snap)
    return False

GLib.timeout_add(900, grab)
m.run_lock_gui()
