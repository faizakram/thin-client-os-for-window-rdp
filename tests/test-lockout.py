"""Lock-screen password policy and the 3-attempt lockout (security plan A4).

Walks the whole story: wrong guesses, the lockout, a reboot, the manager not yet
knowing, the manager acknowledging, an administrator unlocking. And first, the
guarantee that with no policy the lock screen behaves exactly as it always has.
"""
import importlib.machinery, importlib.util, json, os, sys, tempfile, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
tmp = tempfile.mkdtemp()
HOME = os.path.join(tmp, "home"); os.makedirs(HOME)
os.environ["HOME"] = HOME
os.environ["TC_SEC_POLICY"] = os.path.join(tmp, "policy.json")
os.environ["TC_TRUSTED_TIME"] = os.path.join(tmp, "trusted-time")

def load(name, path):
    spec = importlib.util.spec_from_loader(name, importlib.machinery.SourceFileLoader(name, path))
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m); return m

LOCK = os.path.join(ROOT, "scripts", "thinclient-lock")
lk = load("tclock", LOCK)
sp = lk.secpolicy()

ok = 0
def check(name, cond):
    global ok
    assert cond, "FAIL " + name
    ok += 1
    print("  PASS " + name)

def policy(**kw):
    sp.save(kw, os.environ["TC_SEC_POLICY"])

def reset():
    for f in (lk.LOCK_FILE, lk._meta_path(), lk.LOCK_STATE):
        try: os.remove(f)
        except OSError: pass

print("== no policy: exactly the old lock screen ==")
reset()
check("the factory 0000 still unlocks", lk.attempt_unlock("0000") == ("ok", None))
lk.set_password("x")
check("a one-character password can still be set and works", lk.attempt_unlock("x") == ("ok", None))
for i in range(10):
    r = lk.attempt_unlock("wrong")
check("10 wrong guesses: still just 'Incorrect password', never locked", r == ("wrong", "Incorrect password"))
check("…and the right password still works afterwards", lk.attempt_unlock("x") == ("ok", None))
check("new password: only 'not empty' is enforced", lk.validate_new("y") is None and lk.validate_new("") is not None)

print("== the 3-attempt lockout ==")
reset(); lk.set_password("Correct-Horse-9")
policy(lockout={"enabled": True, "attempts": 3})
check("1st wrong: 2 left", lk.attempt_unlock("nope") == ("wrong", "Incorrect password — 2 attempts left"))
check("2nd wrong: warns it is the last", "1 attempt left" in lk.attempt_unlock("nope")[1])
check("3rd wrong: LOCKED", lk.attempt_unlock("nope") == ("locked", None))
check("now even the CORRECT password is refused", lk.attempt_unlock("Correct-Horse-9") == ("locked", None))

print("== a reboot does not reset the count ==")
reset(); lk.set_password("Correct-Horse-9")
lk.attempt_unlock("nope"); lk.attempt_unlock("nope")
lk2 = load("tclock2", LOCK)                       # a fresh process after a restart
check("2 wrong, restart, 1 more wrong: locked", lk2.attempt_unlock("nope") == ("locked", None))

print("== the change-password form is not a way round it ==")
reset(); lk.set_password("Correct-Horse-9")
lk.attempt_current("nope"); lk.attempt_current("nope")
check("3rd wrong CURRENT password locks it too", lk.attempt_current("nope") == ("locked", None))

print("== a correct password resets the count, a lockout is not reset by it ==")
reset(); lk.set_password("Correct-Horse-9")
lk.attempt_unlock("nope"); lk.attempt_unlock("nope")
check("correct on the 3rd try unlocks", lk.attempt_unlock("Correct-Horse-9") == ("ok", None))
check("…and the count starts again from zero", "2 attempts left" in lk.attempt_unlock("nope")[1])

print("== password rules ==")
policy(password={"enabled": True, "min_len": 8, "classes": "alnum", "max_age_days": 15, "remind_days": 3, "history": 5})
reset()
check("factory 0000 still unlocks, but a new password is REQUIRED",
      lk.attempt_unlock("0000")[0] == "change")
lk.set_password("abc")                             # set before the policy existed
check("an old weak password is detected at unlock and must be changed", lk.attempt_unlock("abc")[0] == "change")
check("new password too short", "8" in lk.validate_new("ab12"))
check("new password letters only", "letters and numbers" in lk.validate_new("abcdefgh"))
check("a good new password is accepted", lk.validate_new("Strong-Pass1") is None)
lk.set_password("Strong-Pass1")
check("the CURRENT password can't be reused", "recently" in lk.validate_new("Strong-Pass1"))
lk.set_password("Another-Pass2")
check("nor a recent one", "recently" in lk.validate_new("Strong-Pass1"))
check("a fresh, strong password unlocks normally", lk.attempt_unlock("Another-Pass2") == ("ok", None))

day = 86400
m = lk._json_load(lk._meta_path()); m["set_at"] = time.time() - 13 * day; lk._json_save(lk._meta_path(), m)
r = lk.attempt_unlock("Another-Pass2")
check("13 days into a 15-day policy: reminded, 2 days left", r == ("remind", 2))
m["set_at"] = time.time() - 16 * day; lk._json_save(lk._meta_path(), m)
check("16 days: expired, must change", lk.attempt_unlock("Another-Pass2")[0] == "change")
m["set_at"] = time.time(); lk._json_save(lk._meta_path(), m)
sp.note_server_time(time.time() + 20 * day, os.environ["TC_TRUSTED_TIME"])
check("THE CLOCK TRICK: device clock behind the manager's — still expired",
      lk.attempt_unlock("Another-Pass2")[0] == "change")

print("== administrator reset arrives as a HASH ==")
reset(); os.remove(os.environ["TC_TRUSTED_TIME"])
salt = "0123456789abcdef"
h = sp.lock_hash("Admin-Set-7", salt)
# The CLI looks the user up with pwd. Point that lookup at the TEST home: resolving a
# real account would write into a real home directory (an earlier version of this test
# did exactly that on a developer's machine).
import pwd as _pwd, types as _types
_real_getpwnam = _pwd.getpwnam
_pwd.getpwnam = lambda u: _types.SimpleNamespace(pw_dir=HOME, pw_uid=os.getuid(), pw_gid=os.getgid())
rc = lk._cli_set_hash(["thinclient-lock", "set-hash", "%s:%s" % (salt, h), "kiosk"])
check("set-hash succeeds", rc == 0)
check("the admin's password works", lk.attempt_unlock("Admin-Set-7")[0] == "change")
check("…but must be changed first (someone else knows it)", lk.meta().get("must_change") is True)
check("a malformed hash is refused", lk._cli_set_hash(["x", "set-hash", "not-a-hash", "kiosk"]) == 2)
check("the CLI wrote into the test home, nowhere else", lk.LOCK_FILE.startswith(HOME))
check("the plain password was never written anywhere",
      all("Admin-Set-7" not in open(os.path.join(HOME, f)).read() for f in os.listdir(HOME)))

print("== the agent: lockout vs the manager's lock flag ==")
agent = load("tcagent", os.path.join(ROOT, "scripts", "thinclient-agent"))
agent._kiosk_home = lambda: HOME
calls = []
agent.set_admin_lock = lambda locked, *a, **k: calls.append(("lock", locked, a[0] if a else None))
agent._drop_rdp_session = lambda *a: calls.append(("drop",))
reset(); lk.set_password("Correct-Horse-9")
policy(lockout={"enabled": True, "attempts": 3})
for _ in range(3):
    lk.attempt_unlock("nope")
locked_at = int(lk.lock_state()["locked_at"])
check("the report carries the lockout", agent._lockout_report()["lockout"]["locked_at"] == locked_at)

calls.clear()
check("THE TRAP: manager says 'not locked' but hasn't recorded it -> lockout HELD",
      agent._reconcile_lockout(False, None) is True)
check("…as a PERMANENT admin lock, and the RDP session is ended",
      ("lock", True, "permanent") in calls and ("drop",) in calls)
check("an ack for a DIFFERENT, older lockout does not release it",
      agent._reconcile_lockout(False, locked_at - 500) is True)
check("acknowledged but still locked by the manager: held", agent._reconcile_lockout(True, locked_at) is True)
check("acknowledged AND unlocked by an administrator: released", agent._reconcile_lockout(False, locked_at) is False)
check("the count is reset for the operator's fresh tries", lk.lock_state() == {"fails": 0})
check("…so the right password works again", lk.attempt_unlock("Correct-Horse-9") == ("ok", None))
check("with no lockout, the manager's flag is applied as before", agent._reconcile_lockout(False, None) is False)

print("\n  %d passed" % ok)
