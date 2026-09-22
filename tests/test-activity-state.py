"""Does the agent still report a disconnect it slept through?

This is the fleet's biggest data defect (1387 connects, 777 disconnects), so the
recovery path gets a test rather than a hopeful deploy.
"""
import importlib.machinery, importlib.util, json, os, sys, tempfile, time

AGENT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "scripts", "thinclient-agent")

spec = importlib.util.spec_from_loader(
    "tcagent", importlib.machinery.SourceFileLoader(
        "tcagent", AGENT))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

tmp = tempfile.mkdtemp()
m._ACT_FILE = os.path.join(tmp, "activity.json")

ok = 0
def check(name, cond):
    global ok
    assert cond, "FAIL " + name
    ok += 1
    print("  PASS " + name)

# --- the machine was switched off mid-session -------------------------------------
m._ACT_STATE.update({"rdp": True, "locked": False, "idle": False})
m._ACT_QUEUE.clear()
m._save_activity_state(force=True)
died_at = json.load(open(m._ACT_FILE))["at"]

# ...it comes back up, RDP is not running yet, and the agent starts fresh.
m._ACT_STATE.update({"rdp": None, "locked": None, "idle": None})
m._ACT_QUEUE.clear()
m._rdp_connected = lambda: False
m._restore_activity_state()

check("the disconnect the agent slept through IS reported",
      [e["kind"] for e in m._ACT_QUEUE] == ["RDP_DISCONNECT"])
check("it is timestamped when the session was last known alive, not on reboot",
      abs(m._ACT_QUEUE[0]["at"] - died_at) < 0.01)
check("the edge detector knows RDP is now down, so the next connect fires",
      m._ACT_STATE["rdp"] is False)

# --- the agent restarted but RDP never dropped (an OTA update) ---------------------
m._ACT_STATE.update({"rdp": True})
m._ACT_QUEUE.clear()
m._save_activity_state(force=True)
m._ACT_STATE.update({"rdp": None})
m._ACT_QUEUE.clear()
m._rdp_connected = lambda: True
m._restore_activity_state()
check("a session that never dropped is NOT falsely disconnected", m._ACT_QUEUE == [])
check("and the session stays open", m._ACT_STATE["rdp"] is True)

# --- events observed while offline must survive the machine going down -------------
m._ACT_STATE.update({"rdp": False})
m._ACT_QUEUE[:] = [{"kind": "RDP_CONNECT", "at": 111.0}, {"kind": "RDP_DISCONNECT", "at": 222.0}]
m._save_activity_state(force=True)
m._ACT_QUEUE.clear()
m._rdp_connected = lambda: False
m._restore_activity_state()
check("undelivered working time is not lost on a power cut",
      [e["at"] for e in m._ACT_QUEUE] == [111.0, 222.0])

# --- no state file at all (first ever boot) ----------------------------------------
os.remove(m._ACT_FILE)
m._ACT_QUEUE.clear()
m._ACT_STATE.update({"rdp": None, "locked": None, "idle": None})
m._restore_activity_state()
check("a first boot invents nothing", m._ACT_QUEUE == [] and m._ACT_STATE["rdp"] is None)

# --- a corrupt file must not stop the agent ----------------------------------------
open(m._ACT_FILE, "w").write("{not json")
m._restore_activity_state()
check("a corrupt state file is ignored, not fatal", m._ACT_QUEUE == [])

print("\n  %d passed" % ok)
