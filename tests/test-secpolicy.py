"""The device security policy: password rules, lockout, trusted clock, cert pinning.

The first group matters most. With no policy received, every answer must be exactly
what a device did before this module existed — that is what makes it safe to ship the
code to the whole fleet before any protection is switched on.
"""
import importlib.machinery, importlib.util, json, os, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_loader("secpol", importlib.machinery.SourceFileLoader(
    "secpol", os.path.join(os.path.dirname(HERE), "scripts", "thinclient-secpolicy")))
sp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sp)

tmp = tempfile.mkdtemp()
POL = os.path.join(tmp, "policy.json")
CLK = os.path.join(tmp, "trusted-time")

ok = 0
def check(name, cond):
    global ok
    assert cond, "FAIL " + name
    ok += 1
    print("  PASS " + name)

def on(**pw):
    p = sp.normalise({"password": dict({"enabled": True}, **pw)})
    return p

print("== no policy = today's behaviour ==")
none = sp.load(POL)                                   # file does not exist
check("missing policy file loads the defaults", none == sp.normalise({}))
check("password rules OFF: a 1-character password is still accepted", sp.check_password("a", none) is None)
check("…and the factory default is still accepted", sp.check_password("0000", none) is None)
check("…and only an empty password is refused, as today", sp.check_password("", none) == "Password can't be empty")
check("no expiry, ever", sp.password_status({"set_at": 1}, none, now=10**10) == ("ok", None))
check("lockout OFF: wrong guesses count but never lock",
      sp.lockout_after_failure({"fails": 50}, none)[1] is False)
check("certificate pinning OFF: any server allowed, nothing reported",
      sp.pin_decision(none, "1.2.3.4", 3389, "ab" * 32) == ("allow", None))
check("clipboard stays shared", none["clipboard"] is True)
check("USB storage not blocked", none["usb_storage_block"] is False)
check("memory hardening not applied", none["mem_harden"] is False)

print("== hostile / malformed policy values fall back safely ==")
bad = sp.normalise({"lockout": {"enabled": True, "attempts": 0}, "cert_pin": "yes",
                    "password": {"enabled": True, "min_len": -5, "classes": "x", "max_age_days": "lots"}})
check("lockout of 0 attempts is raised to the minimum of 3", bad["lockout"]["attempts"] == 3)
check("an unknown pin mode is OFF, not enforce", bad["cert_pin"] == "off")
check("a negative minimum length is raised to 4", bad["password"]["min_len"] == 4)
check("an unknown class rule is letters+digits", bad["password"]["classes"] == "alnum")
check("a non-number max age falls back to 15", bad["password"]["max_age_days"] == 15)
check("unknown keys are dropped", "evil" not in sp.normalise({"evil": 1}))

print("== save / load round trip ==")
check("first save reports a change", sp.save({"lockout": {"enabled": True}}, POL) is True)
check("saving the same policy again reports no change", sp.save({"lockout": {"enabled": True}}, POL) is False)
check("it reloads as saved", sp.load(POL)["lockout"]["enabled"] is True)
check("the file is world-readable (the lock screen runs as the kiosk user)",
      oct(os.stat(POL).st_mode & 0o777) == "0o644")

print("== password rules ==")
p = on(min_len=8, classes="alnum")
check("the factory default is refused", "factory" in sp.check_password("0000", p))
check("too short is refused with the length", "8" in sp.check_password("ab12", p))
check("letters only is refused", "letters and numbers" in sp.check_password("abcdefgh", p))
check("digits only is refused under alnum", "letters and numbers" in sp.check_password("12345678", p))
check("letters + digits of 8 is accepted", sp.check_password("abcd1234", p) is None)
d = on(min_len=6, classes="digits")
check("digits-only mode accepts a 6-digit PIN", sp.check_password("482915", d) is None)
check("digits-only mode refuses letters", "digits only" in sp.check_password("48291a", d))
s = on(min_len=8, classes="alnum_symbol")
check("symbol mode needs a symbol", "symbol" in sp.check_password("abcd1234", s))
check("symbol mode accepts one", sp.check_password("abcd123!", s) is None)

print("== expiry, against the TRUSTED clock ==")
p = on(max_age_days=15, remind_days=3)
day = 86400
check("fresh password is fine", sp.password_status({"set_at": 1000}, p, now=1000 + 2 * day) == ("ok", None))
check("3 days before expiry it reminds", sp.password_status({"set_at": 0.1}, p, now=0.1 + 12.5 * day)[0] == "remind")
check("after 15 days it has expired", sp.password_status({"set_at": 1000}, p, now=1000 + 16 * day) == ("expired", None))
check("a 7-day policy expires on day 8", sp.password_status({"set_at": 1000}, on(max_age_days=7), now=1000 + 8 * day)[0] == "expired")
check("max age 0 = never expires", sp.password_status({"set_at": 1}, on(max_age_days=0), now=10**10) == ("ok", None))
check("the factory default must be changed", sp.password_status({"is_default": True}, p)[0] == "must_change")
check("an admin reset must be changed", sp.password_status({"must_change": True}, p)[0] == "must_change")
check("a password found weak at unlock must be changed", sp.password_status({"weak": True}, p)[0] == "must_change")

sp.note_server_time(time.time() + 40 * day, CLK)       # the manager vouched for a later time
check("THE CLOCK TRICK: setting the device clock back does not stop expiry",
      sp.password_status({"set_at": time.time()}, p, now=sp.trusted_now(CLK))[0] == "expired")
before = sp.trusted_floor(CLK)
sp.note_server_time(1000, CLK)
check("the trusted time never moves backwards", sp.trusted_floor(CLK) == before)

print("== lockout ==")
lo = sp.normalise({"lockout": {"enabled": True, "attempts": 3}})
st = {}
st, locked = sp.lockout_after_failure(st, lo); check("1st wrong: not locked", not locked)
st, locked = sp.lockout_after_failure(st, lo); check("2nd wrong: not locked", not locked)
st, locked = sp.lockout_after_failure(st, lo); check("3rd wrong: LOCKED", locked)
check("the lock time is recorded, unreported", st.get("locked_at") and st.get("reported") is False)
first = st["locked_at"]
st, locked = sp.lockout_after_failure(st, lo, now=first + 99)
check("further failures keep it locked and keep the ORIGINAL lock time", locked and st["locked_at"] == first)
check("clearing resets the count", sp.lockout_cleared() == {"fails": 0})

print("== password history (no plain passwords kept) ==")
salt = "00" * 8
hist = [salt + ":" + sp.lock_hash("old-pass-1", salt)]
check("a recent password is recognised", sp.reused("old-pass-1", hist, sp.lock_hash))
check("a new one is not", not sp.reused("brand-new-9", hist, sp.lock_hash))
check("a corrupt history entry is ignored, not a crash", not sp.reused("x", ["garbage"], sp.lock_hash))

print("== certificate pinning ==")
fp = "AB:" * 31 + "AB"
check("fingerprints normalise from colon form", sp.normalise_fp(fp) == "ab" * 32)
check("…and from sha256: prefix", sp.normalise_fp("sha256:" + "ab" * 32) == "ab" * 32)
check("a non-fingerprint is rejected", sp.normalise_fp("not-a-hash") is None)
rep = sp.normalise({"cert_pin": "report", "cert_pins": {"10.0.0.5:3389": ["ab" * 32]}})
enf = sp.normalise({"cert_pin": "enforce", "cert_pins": {"10.0.0.5:3389": ["ab" * 32]}})
check("no pin yet for a server: LEARN and allow", sp.pin_decision(rep, "10.0.0.9", 3389, "cd" * 32) == ("learn", "cd" * 32))
check("matching pin: allow", sp.pin_decision(enf, "10.0.0.5", 3389, fp) == ("allow", None))
check("REPORT mode mismatch: allow but WARN", sp.pin_decision(rep, "10.0.0.5", 3389, "cd" * 32)[0] == "warn")
check("ENFORCE mode mismatch: REFUSE", sp.pin_decision(enf, "10.0.0.5", 3389, "cd" * 32)[0] == "refuse")
check("host matching ignores case", sp.pin_decision(enf, "10.0.0.5".upper(), 3389, fp) == ("allow", None))
check("enforce with an unreadable fingerprint refuses rather than passes",
      sp.pin_decision(enf, "10.0.0.5", 3389, "garbage")[0] == "refuse")

print("\n  %d passed" % ok)
