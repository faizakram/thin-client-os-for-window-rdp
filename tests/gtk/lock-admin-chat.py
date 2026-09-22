"""Drive the real lock screen under Xvfb: does the admin-lock message pane work?

The unit tests cover the data. This covers the part that only fails on a real GTK
stack — and it runs on the one screen an operator cannot walk away from.
"""
import importlib.machinery, importlib.util, json, os, sys, tempfile
import gi
gi.require_version("Gtk", "3.0")
from gi.repository import Gtk, GLib

# "already" = the device was admin-locked before the lock screen started (a reboot
# while locked, or Super+L after the admin locked). "later" = the operator was at
# their own lock screen and the administrator locked them while they sat there —
# the case this feature was reported for.
SCENARIO = sys.argv[1] if len(sys.argv) > 1 else "already"
tmp = tempfile.mkdtemp()
admin = os.path.join(tmp, "admin-lock")
if SCENARIO == "already":
    open(admin, "w").write("0\npermanent\n0\n")
os.environ["TC_LICENSE_ADMIN_LOCK"] = admin

spec = importlib.util.spec_from_loader(
    "tclock", importlib.machinery.SourceFileLoader("tclock", os.environ.get("TC_LOCK_SRC", "/src/scripts/thinclient-lock")))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
m.CHAT_LOG = os.path.join(tmp, "log.jsonl")
m.CHAT_OUTBOX = os.path.join(tmp, "outbox")
m.CHAT_ACTIVE = os.path.join(tmp, "chat-active")
m.CHAT_UNREAD = os.path.join(tmp, "chat-unread")
with open(m.CHAT_LOG, "w") as f:
    f.write(json.dumps({"sender": "admin", "body": "You are locked for a review"}) + "\n")

fails = []
def check(name, cond):
    print(("  PASS " if cond else "  FAIL ") + name)
    if not cond:
        fails.append(name)

def drive():
    win = next((w for w in Gtk.Window.list_toplevels()
                if w.__class__.__name__ == "LockScreen"), None)
    if win is None:
        fails.append("lock window never appeared"); Gtk.main_quit(); return False

    check("the lock screen builds and maps", win.get_visible())

    if SCENARIO == "later":
        # Before the administrator does anything: an ordinary lock.
        check("an ordinary lock offers the password box", win.entry.get_visible())
        check("and does NOT offer to message the administrator — they can just unlock",
              not win.msg_link.get_visible())
        open(admin, "w").write("0\npermanent\n0\n")   # the administrator locks them
        win._tick()

    check("it is in admin-wait mode", win.mode == "adminwait")
    check("the password box is hidden — the operator cannot clear this lock",
          not win.entry.get_visible())
    # MAPPED, not merely visible, and on the BUBBLE itself rather than the button that
    # holds it. The first version of this test asked whether the button was visible and
    # whether the DrawingArea object existed — both true while the operator stared at
    # an empty button, because show() does not map a widget's children. Test the thing
    # somebody actually looks at.
    check("the chat bubble is on screen", win.msg_link.get_mapped())
    kids = win.msg_link.get_children()
    check("the button has its bubble row", len(kids) == 1 and kids[0].get_mapped())
    drawn = [c for c in kids[0].get_children() if c.get_mapped()]
    check("both the bubble and its label are mapped", len(drawn) == 2)
    if m.HAVE_CAIRO:
        check("and the bubble is the Cairo one, drawn and mapped",
              win.bubble is not None and win.bubble.get_mapped())
    check("the bubble is drawn at the launcher's accent colours",
          (m.BUBBLE_A1, m.BUBBLE_A2) == ((0x3d, 0x7b, 0xf5), (0x6d, 0x5e, 0xfc)))
    check("the message pane starts closed", not win.msg_box.get_visible())

    win._open_msg()
    check("opening the pane shows it", win.msg_box.get_visible())
    check("and its children actually map (the no-show-all trap)",
          win.msg_entry.get_visible() and win.msg_list.get_visible())
    rows = win.msg_list.get_children()
    check("the administrator's message is on screen", len(rows) == 1)

    win.msg_entry.set_text("I am at my desk, please unlock")
    win._send_msg()
    queued = sorted(os.listdir(m.CHAT_OUTBOX))
    check("sending queues it for the agent", len(queued) == 1)
    check("the box is cleared after sending", win.msg_entry.get_text() == "")
    check("and the operator sees it listed straight away",
          len(win.msg_list.get_children()) == 2)

    # An unread badge must appear if the administrator has already written.
    open(m.CHAT_UNREAD, "w").write("3")
    win._tick()
    check("the unread badge redraws while the operator waits at the lock",
          os.path.exists(m.CHAT_UNREAD) and m._chat_unread() == 3)
    check("the tick marks chat active so replies arrive quickly",
          os.path.exists(m.CHAT_ACTIVE))

    win._close_msg()
    check("hiding the pane brings the bubble back, children and all",
          not win.msg_box.get_visible() and win.msg_link.get_mapped()
          and all(c.get_mapped() for c in win.msg_link.get_children()[0].get_children()))

    # The lock must still refuse to open, message pane or not.
    win.entry.set_text("whatever")
    win._submit()
    check("the lock still cannot be unlocked by the operator", win.get_visible())

    # No stray toplevel: everything lives inside the lock window, so nothing new can
    # be reached from behind it.
    tops = [w for w in Gtk.Window.list_toplevels() if w.get_visible()]
    check("no second window was ever mapped", len(tops) == 1)

    Gtk.main_quit()
    return False

GLib.timeout_add(700, drive)
m.run_lock_gui()
print("\n  [%s] %d failed" % (SCENARIO, len(fails)))
sys.exit(1 if fails else 0)
