"""Reaching the administrator from an admin lock.

The lock screen is the one place on this appliance an operator cannot walk away
from, so the code that runs there gets tested rather than eyeballed. These cover the
data side — history, sending, the attachment guard — which is all of it that can be
exercised without an X display.
"""
import importlib.machinery, importlib.util, json, os, shutil, tempfile

LOCK = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                    "scripts", "thinclient-lock")
spec = importlib.util.spec_from_loader("tclock", importlib.machinery.SourceFileLoader("tclock", LOCK))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

tmp = tempfile.mkdtemp()
m.CHAT_LOG = os.path.join(tmp, "log.jsonl")
m.CHAT_OUTBOX = os.path.join(tmp, "outbox")

ok = 0
def check(name, cond):
    global ok
    assert cond, "FAIL " + name
    ok += 1
    print("  PASS " + name)

def log(*entries):
    with open(m.CHAT_LOG, "w") as f:
        for e in entries:
            f.write(json.dumps(e) + "\n")

# --- reading the conversation ------------------------------------------------------
log({"sender": "admin", "body": "Locking you out for a moment", "at": 1},
    {"sender": "device", "body": "Understood", "at": 2})
check("both sides of the conversation are shown, oldest first",
      m._chat_history() == [("Administrator", "Locking you out for a moment"), ("You", "Understood")])

# --- the attachment guard ----------------------------------------------------------
# The whole point of an admin lock is that nothing else can be reached from it, so an
# image must never become something to open from this screen.
log({"sender": "admin", "body": "", "attachment": "/var/lib/thinclient/chat/img/x.png", "at": 3})
hist = m._chat_history()
check("an attachment becomes a note, never a path or a file to open",
      hist == [("Administrator", "(attachment — you can open it after unlocking)")])
check("and no filesystem path reaches the screen", "/var/lib" not in hist[0][1])

# --- sending -----------------------------------------------------------------------
log()
check("nothing to show before anything is said", m._chat_history() == [])
check("a message is queued for the agent", m._chat_send("Please unlock me") is True)
queued = os.listdir(m.CHAT_OUTBOX)
check("exactly one plain-text outbox item", len(queued) == 1 and queued[0].endswith(".txt"))
check("with the operator's words, unchanged",
      open(os.path.join(m.CHAT_OUTBOX, queued[0])).read() == "Please unlock me")
check("an undelivered message still shows, so it does not vanish while it waits",
      m._chat_history() == [("You", "Please unlock me  (sending…)")])

check("an empty message is not sent", m._chat_send("   ") is False)
check("and queues nothing", len(os.listdir(m.CHAT_OUTBOX)) == 1)

long = "x" * 5000
m._chat_send(long)
sent = sorted(os.listdir(m.CHAT_OUTBOX))
check("an over-long message is capped rather than refused",
      any(len(open(os.path.join(m.CHAT_OUTBOX, n)).read()) == m.MSG_MAX for n in sent))

# --- failing safe ------------------------------------------------------------------
shutil.rmtree(tmp)
m.CHAT_LOG = os.path.join(tmp, "gone.jsonl")
m.CHAT_OUTBOX = os.path.join(tmp, "gone")
check("a missing chat log is an empty conversation, not a crash on the lock screen",
      m._chat_history() == [])
check("a missing outbox directory is created on demand",
      m._chat_send("hello") is True)

m.CHAT_LOG = os.path.join(tmp, "bad.jsonl")
m.CHAT_OUTBOX = os.path.join(tmp, "empty-outbox")   # isolate from the send above
os.makedirs(tmp, exist_ok=True)
open(m.CHAT_LOG, "w").write("{not json\n" + json.dumps({"sender": "admin", "body": "still fine"}) + "\n")
check("a corrupt line is skipped, and the rest still shows",
      m._chat_history() == [("Administrator", "still fine")])

# --- the bubble must keep matching the chat launcher --------------------------------
# The lock draws its own copy of the launcher bubble (it cannot import a whole GUI app,
# and the bundle ships only shell files in lib/). Duplication is fine as long as drift
# is loud, so: if somebody restyles the launcher, this fails and points at the lock.
import re
CHAT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                    "scripts", "thinclient-chat")
chat_src = open(CHAT).read()

def _tuple(src, name):
    m = re.search(name + r"\s*=\s*\(([^)]*)\)", src)
    return tuple(int(x.strip(), 0) for x in m.group(1).split(",")) if m else None

check("the lock's bubble uses the launcher's accent start colour",
      m.BUBBLE_A1 == _tuple(chat_src, "C_A1"))
check("and its accent end colour",
      m.BUBBLE_A2 == _tuple(chat_src, "C_A2"))
check("and the same unread badge colour",
      m.BUBBLE_BADGE == _tuple(chat_src, "C_BADGE"))
check("and the same bubble size as the launcher",
      m.BUBBLE_SIZE == int(re.search(r"SIZE\s*=\s*(\d+)", chat_src).group(1)))
check("the no-pycairo fallback glyph matches the launcher's envelope",
      "\u2709" in open(LOCK).read() and "\u2709" in chat_src)

print("\n  %d passed" % ok)
