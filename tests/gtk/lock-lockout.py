"""Drive the real lock screen under Xvfb through the security-plan flows (A4):
the 3-attempt lockout, the administrator lifting it, a forced password change and an
expiry reminder. Asserts what is MAPPED on screen, not what merely exists — the lesson
of the earlier lock-screen bugs (see README).

    lockout  — 3 wrong, locked; admin lock arrives; admin lifts it; back to a password
    change   — the factory password under a policy: a new one is required first
    remind   — a password about to expire: reminded, can continue or change
"""
import importlib.machinery, importlib.util, json, os, sys, tempfile, time
import gi
gi.require_version("Gtk", "3.0")
from gi.repository import Gtk, GLib

SCENARIO = sys.argv[1] if len(sys.argv) > 1 else "lockout"
tmp = tempfile.mkdtemp()
os.environ["HOME"] = tmp
os.environ["TC_LICENSE_ADMIN_LOCK"] = admin = os.path.join(tmp, "admin-lock")
os.environ["TC_SEC_POLICY"] = os.path.join(tmp, "policy.json")
os.environ["TC_TRUSTED_TIME"] = os.path.join(tmp, "trusted-time")
SRC = os.environ.get("TC_LOCK_SRC", "/src/scripts/thinclient-lock")

spec = importlib.util.spec_from_loader("tclock", importlib.machinery.SourceFileLoader("tclock", SRC))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
for k in ("CHAT_LOG", "CHAT_ACTIVE", "CHAT_UNREAD"):
    setattr(m, k, os.path.join(tmp, k.lower()))
m.CHAT_OUTBOX = os.path.join(tmp, "outbox")
sp = m.secpolicy()
assert sp, "the shared policy module did not load next to the lock screen"

if SCENARIO == "lockout":
    sp.save({"lockout": {"enabled": True, "attempts": 3}})
    m.set_password("Correct-Horse-9")
elif SCENARIO == "change":
    sp.save({"password": {"enabled": True}})          # no lock file = factory 0000
elif SCENARIO == "remind":
    sp.save({"password": {"enabled": True, "max_age_days": 15, "remind_days": 3}})
    m.set_password("Good-Pass-77")
    meta = m._json_load(m._meta_path()); meta["set_at"] = time.time() - 13 * 86400
    m._json_save(m._meta_path(), meta)

fails = []
def check(name, cond):
    print(("  PASS " if cond else "  FAIL ") + name)
    if not cond:
        fails.append(name)

def type_and_submit(win, text):
    win.entry.set_text(text)
    win._submit()

def drive():
    win = next((w for w in Gtk.Window.list_toplevels()
                if w.__class__.__name__ == "LockScreen"), None)
    if win is None:
        fails.append("lock window never appeared"); Gtk.main_quit(); return False
    check("the lock screen builds and maps", win.get_mapped())

    if SCENARIO == "lockout":
        type_and_submit(win, "nope")
        check("1st wrong shows how many tries are left", "2 attempts left" in win.err.get_text())
        type_and_submit(win, "nope")
        check("2nd wrong warns it is the last", "1 attempt left" in win.err.get_text())
        type_and_submit(win, "nope")
        check("3rd wrong: the lockout screen", win.mode == "lockedout")
        check("it says why", win.title_lbl.get_text() == m.LOCKOUT_TITLE)
        check("the password box is GONE from the screen", not win.entry.get_mapped())
        check("the unlock button is gone too", not win.btn.get_mapped())
        check("the way to message the administrator IS on screen", win.msg_link.get_mapped())
        win.entry.set_text("Correct-Horse-9"); win._submit()
        check("the correct password no longer opens it", win.get_mapped() and win.mode == "lockedout")

        # The agent raises the admin lock (as it does on its next tick).
        open(admin, "w").write("%d\npermanent\n24\n\n" % int(time.time()))
        win._tick()
        check("as an admin lock it STILL says it was a lockout, not 'working hours'",
              win.title_lbl.get_text() == m.LOCKOUT_TITLE)
        check("still no password box", not win.entry.get_mapped())

        # An administrator presses Unlock: the agent clears the lockout and the lock.
        os.remove(admin)
        m._json_save(m.LOCK_STATE, {"fails": 0})
        win._tick()
        check("lifted: the screen is NOT opened straight into the desktop", win.get_mapped())
        check("…it asks for the password again", win.mode == "unlock" and win.entry.get_mapped())
        check("…and says the administrator unlocked it", "administrator" in win.sub_lbl.get_text())
        check("the message bubble is put away", not win.msg_link.get_mapped())
        type_and_submit(win, "nope")
        check("with a FRESH set of tries", "2 attempts left" in win.err.get_text())

    elif SCENARIO == "change":
        type_and_submit(win, "0000")
        check("the factory password leads to 'Set a new password'", win.title_lbl.get_text() == "Set a new password")
        check("the password box is on screen for it", win.entry.get_mapped())
        check("there is no 'Change password' escape link", not win.change_link.get_mapped())
        type_and_submit(win, "short1")
        check("a password breaking the rules is refused with the reason", "8" in win.err.get_text())
        type_and_submit(win, "Brand-New-Pass1")
        check("a good one moves on to confirmation", win.mode == "confirm")

    elif SCENARIO == "remind":
        type_and_submit(win, "Good-Pass-77")
        check("a password about to expire shows the reminder", win.mode == "remind")
        check("with the days left", "2 days" in win.title_lbl.get_text())
        check("no password box on the reminder", not win.entry.get_mapped())
        check("a Continue button", win.btn.get_mapped() and win.btn.get_label() == "Continue")
        check("and a 'Change it now' link", win.change_link.get_mapped())
        win._start_change()
        check("'Change it now' goes straight to a NEW password (current one just proven)",
              win.mode == "new" and win.entry.get_mapped())

    tops = [w for w in Gtk.Window.list_toplevels() if w.get_visible()]
    check("no second window was ever mapped", len(tops) == 1)
    Gtk.main_quit()
    return False

GLib.timeout_add(700, drive)
m.run_lock_gui()
print("\n  [%s] %d failed" % (SCENARIO, len(fails)))
sys.exit(1 if fails else 0)
