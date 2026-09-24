"""Camera USB drop and automatic recovery.

Taken from a real fault on Faiz-testing-005, 20 Sep 2026. The device journal:

    15:05:59  kernel: usb 3-1: USB disconnect, device number 2
    15:06:00  agent:  recording restart (camera handoff)
    15:06:00  kernel: usb 3-1: new high-speed USB device number 6   <- already back
    15:06:00  agent:  HLS recording cmu9mfpxx... started            <- born screen-only
    15:06:05  agent:  camera device is /dev/video0                  <- 5s too late

The camera was gone for about ONE SECOND. The recording that started inside that
second ran for 109 minutes with screen=2179 segments and camera=0, because a
screen-only session was never upgraded mid-run. These tests pin the three behaviours
that make that impossible: a brief absence is not an unplug, a screen-only session
can be upgraded exactly once, and a real outage triggers a software replug.
"""
import importlib.machinery, importlib.util, os, tempfile, time

AGENT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                     "scripts", "thinclient-agent")
spec = importlib.util.spec_from_loader("tcagent", importlib.machinery.SourceFileLoader("tcagent", AGENT))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

ok = 0
def check(name, cond):
    global ok
    assert cond, "FAIL " + name
    ok += 1
    print("  PASS " + name)

# ---- _usb_dir_for_node: resolve /dev/videoN -> the USB device that owns power/control
tmp = tempfile.mkdtemp()
usbdev = os.path.join(tmp, "sys", "bus", "usb", "devices", "3-1")
iface = os.path.join(usbdev, "3-1:1.0")
os.makedirs(iface)
open(os.path.join(usbdev, "idVendor"), "w").write("0c45\n")     # the DEVICE has idVendor
os.makedirs(os.path.join(tmp, "sys", "class", "video4linux", "video0"))
os.symlink(iface, os.path.join(tmp, "sys", "class", "video4linux", "video0", "device"))

real_realpath, real_exists = os.path.realpath, os.path.exists
os.path.realpath = lambda p: real_realpath(p.replace("/sys", os.path.join(tmp, "sys"), 1)) \
    if p.startswith("/sys") else real_realpath(p)
os.path.exists = lambda p: real_exists(p.replace("/sys", os.path.join(tmp, "sys"), 1)) \
    if p.startswith("/sys") else real_exists(p)
try:
    got = m._usb_dir_for_node("/dev/video0")
    check("resolves the node to the USB DEVICE, not its interface", got.endswith("3-1"))
    check("a nonexistent node resolves to nothing", m._usb_dir_for_node("/dev/video9") == "")
    check("an empty node resolves to nothing", m._usb_dir_for_node("") == "")
finally:
    os.path.realpath, os.path.exists = real_realpath, real_exists

# ---- the composite-device guard: never reset a camera that is also the live mic
check("no sound function -> reset is safe", m._cam_owns_active_mic(tmp) is False)
check("unresolvable device -> reset is skipped", m._cam_owns_active_mic("") is False)

snd = os.path.join(tmp, "sound", "card2")
os.makedirs(snd)
real_run = m.subprocess.run
class R:
    def __init__(s, out): s.stdout = out
m.subprocess.run = lambda *a, **k: R(" 1234\n")     # fuser reports a holder
check("webcam mic IN USE -> reset refused (would cut a live call)",
      m._cam_owns_active_mic(tmp) is True)
m.subprocess.run = lambda *a, **k: R("")            # nobody holds it
check("webcam mic idle -> reset allowed", m._cam_owns_active_mic(tmp) is False)
def boom(*a, **k): raise OSError("no fuser")
m.subprocess.run = boom
check("cannot tell who holds the mic -> fail SAFE, refuse the reset",
      m._cam_owns_active_mic(tmp) is True)
m.subprocess.run = real_run

# ---- the settle window: a one-second re-enumeration is NOT an unplug
now = time.time()
m._CAM_HEALTH.update({"lost_at": now - 1.0, "node": "/dev/video0", "reported": False})
settling = (m._CAM_HEALTH["lost_at"] and
            now - m._CAM_HEALTH["lost_at"] < m._CAM_SETTLE_SECS)
check("gone for 1s is treated as re-enumeration, not unplug", bool(settling))
m._CAM_HEALTH["lost_at"] = now - 30.0
settled = now - m._CAM_HEALTH["lost_at"] >= m._CAM_SETTLE_SECS
check("gone for 30s is a real outage", bool(settled))
check("the settle window is longer than the ~1s gap seen on real hardware",
      m._CAM_SETTLE_SECS > 1.0)

# ---- reset throttling: never loop forever on a genuinely unplugged camera
m._CAM_HEALTH.update({"resets": 0, "last_reset": time.time()})
check("a second reset inside the backoff window is refused",
      m._camera_usb_reset("/dev/video0") == "")
m._CAM_HEALTH.update({"resets": m._CAM_RESET_MAX, "last_reset": 0.0})
check("stops replugging after the attempt cap (waits for a human)",
      m._camera_usb_reset("/dev/video0") == "")
check("the cap is small enough not to thrash the bus", m._CAM_RESET_MAX <= 6)
check("the backoff is at least a minute", m._CAM_RESET_BACKOFF >= 60)

# ---- the PERMANENT fix: recovery when the camera is GONE from sysfs
#
# On 20 Sep a camera failed with "device not accepting address, error -71" and
# vanished from sysfs entirely. Every recovery path that starts from /dev/videoN then
# has nothing to work with — which is exactly when recovery matters. The port belongs
# to the hub, not the camera, so it survives and can still be cycled.
check("a root-hub device maps to its hub port",
      "usb3-port1" in (m._usb_port_dir("/sys/bus/usb/devices/3-1") or "usb3-port1-NOTFOUND"))
check("a device behind a hub maps to that hub's port",
      "3-2-port1" in (m._usb_port_dir("/sys/bus/usb/devices/3-2.1") or "3-2-port1-NOTFOUND"))
check("nonsense paths derive nothing", m._usb_port_dir("") == "" and m._usb_port_dir("/sys/x") == "")
check("a missing port directory is not an error", m._usb_port_cycle("") is False)
check("a port with no disable attribute is not an error",
      m._usb_port_cycle(tmp) is False)

# The remembered location is what makes the above reachable during a hard failure.
src_ = open(AGENT).read()
check("the camera's USB location is remembered while it is HEALTHY",
      '_CAM_HEALTH["usb_dir"] = ud' in src_)
check("recovery falls back to the remembered location when the node is gone",
      'or _CAM_HEALTH.get("usb_dir", "")' in src_)
check("the port cycle is the last rung of the ladder", 'return "portcycle"' in src_)
check("attempts resume after a quiet spell instead of giving up for ever",
      m._CAM_RESET_WINDOW >= 600)

# A port cycle must never pull power from the headset/Bluetooth port next door.
port = os.path.join(tmp, "portX"); os.makedirs(port, exist_ok=True)
open(os.path.join(port, "disable"), "w").write("0")
other = os.path.join(tmp, "otherdev"); os.makedirs(other, exist_ok=True)
open(os.path.join(other, "idVendor"), "w").write("1a40\n")
open(os.path.join(other, "idProduct"), "w").write("0101\n")
try: os.symlink(other, os.path.join(port, "device"))
except FileExistsError: pass
check("refuses to cycle a port now holding a DIFFERENT device (the headset hub)",
      m._usb_port_cycle(port, "0c45", "636b") is False)
os.remove(os.path.join(port, "device"))
check("an EMPTY port is cycled - that is the failure being recovered from",
      m._usb_port_cycle(port, "0c45", "636b") is True)

# ---- events: the fault is invisible without them
m._ACT_QUEUE.clear()
m._cam_event("CAMERA_LOST", node="/dev/video0")
m._cam_event("CAMERA_RECOVERED", node="/dev/video0", downSec=4.2, recoveredBy="usbreset")
check("both camera events are queued for the manager", len(m._ACT_QUEUE) == 2)
check("the lost event names the node", m._ACT_QUEUE[0]["meta"]["node"] == "/dev/video0")
check("the recovery event records how long and how",
      m._ACT_QUEUE[1]["meta"]["downSec"] == 4.2 and
      m._ACT_QUEUE[1]["meta"]["recoveredBy"] == "usbreset")
check("empty metadata fields are dropped, not sent as blanks",
      "reason" not in m._ACT_QUEUE[0]["meta"])

# ---- the settle window must actually GATE something
#
# It was once computed and then never used, which reads fine and fixes nothing: the
# recorder still started a screen-only session inside the re-enumeration gap. This
# checks the decision is wired to a guard, not just calculated.
src = open(AGENT).read()
check("the settle window blocks starting a new session",
      "if cam_settling and _REC_SESSION is None:" in src)
check("a screen-only session can be upgraded exactly once",
      "_REC_SESSION[\"cam_upgraded\"] = True" in src and
      'not _REC_SESSION.get("cam_upgraded")' in src)
check("an upgrade rolls a fresh file instead of resuming the screen-only pipeline",
      "not must_drop_cam and not cam_upgrade and not must_drop_mic" in src)
check("no-autosuspend is applied at startup, not merely defined",
      "threading.Thread(target=_ensure_camera_stable" in src)

# ---- THE REGRESSION that broke recording on the canary, 20 Sep 2026
#
# Removing the 60s re-probe without adding a failure trigger meant a node chosen
# wrongly during a re-enumeration ("camera device is /dev/video1 (was /dev/video0)",
# one second after the camera came back) stuck for the whole trust window, and every
# capture died with "Error opening input file /dev/video1" — churning 5-second
# recordings for half an hour.
check("a camera failure re-probes the node instead of trusting the cached one",
      '_CAM_DEV["dev"], _CAM_DEV["at"] = "", 0.0' in src)
check("the trust window is a safety net, not a ten-minute stick",
      m._CAM_DEV_RETRUST <= 180.0)

# ---- telemetry must not flatter the code (found in production, 20 Sep 2026)
#
# The agent cycled the old port seven times, the camera never came back there, a
# person moved it to a different socket — and the event still read
# recoveredBy="portcycle". A rollout decision would have been made on that.
src2 = open(AGENT).read()
check("a recovery method is only credited on the SAME port",
      'same_port = (usb_dir and usb_dir == _CAM_HEALTH.get("tried_port"))' in src2)
check("...and only if the camera returned SOON after the attempt",
      '_CAM_HEALTH.get("tried_at", 0)) < 45' in src2)
check("otherwise the recovery is honestly attributed to a human",
      'else "self"' in src2)
check("the port acted on is recorded so the check is possible",
      '_CAM_HEALTH["tried_port"] = usb_dir' in src2)

# ---- a camera that MOVES socket must be re-learned
# The remembered location used to be captured once and never updated, so after
# somebody replugged into a different port the agent would cycle the old, now-empty
# port for ever and never find where the camera actually went.
check("the camera's location is re-learned when it moves",
      'ud_now and ud_now != _CAM_HEALTH.get("usb_dir")' in src2)

# ---- the re-probe that caused ~60 USB resume cycles an hour
check("a node that still exists is not re-probed every 60s any more",
      m._CAM_DEV_RETRUST > 60.0)

# --- a recording is only healthy when EVERY source is still moving ----------------
#
# _rec_session_stalled used to take the FRESHEST index mtime across screen and camera.
# One healthy stream therefore masked a dead one: on 23 Sep Joey's screen stopped
# producing segments at 17:02 while his camera ran on until 17:53, and the camera's
# fresh timestamp kept answering "not stalled" while the machine recorded no screen at
# all for fifty minutes.
import tempfile as _tf
_d = _tf.mkdtemp()
os.makedirs(os.path.join(_d, "screen"), exist_ok=True)
os.makedirs(os.path.join(_d, "camera"), exist_ok=True)

def _touch(src, age):
    f = os.path.join(_d, src, "index.m3u8")
    open(f, "w").write("#EXTM3U\n")
    os.utime(f, (time.time() - age, time.time() - age))

def _sess(camera=True, age=None):
    return {"hls": True, "camera": camera, "outdir": _d,
            "started": time.time() - 9999, "started_run": time.time() - 9999}

STALE = m._REC_STALL_SECS + 30

_touch("screen", 1); _touch("camera", 1)
check("both sources moving is not a stall", m._rec_session_stalled(_sess()) is False)

_touch("screen", STALE); _touch("camera", 1)
check("a DEAD SCREEN is a stall even while the camera is healthy",
      m._rec_session_stalled(_sess()) is True)

_touch("screen", 1); _touch("camera", STALE)
check("a dead camera is a stall even while the screen is healthy",
      m._rec_session_stalled(_sess()) is True)

# A screen-only recording must not be judged on a camera it never captures.
_touch("screen", 1); _touch("camera", STALE)
check("a screen-only session ignores a stale camera index",
      m._rec_session_stalled(_sess(camera=False)) is False)

os.remove(os.path.join(_d, "screen", "index.m3u8"))
check("a source that never produced an index at all is a stall",
      m._rec_session_stalled(_sess(camera=False)) is True)

_touch("screen", 1); _touch("camera", 1)
_young = _sess(); _young["started_run"] = time.time()
check("a just-started run is given its grace period",
      m._rec_session_stalled(_young) is False)

print("\n  %d checks passed" % ok)
