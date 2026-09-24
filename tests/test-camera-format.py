"""Camera capture variants and the per-camera format cache.

This fault has cost several releases. The failure it guards against is specific and
was taken from a real device: an "HD 2MP WEBCAM" that ADVERTISES MJPG at 640x480/10,
captures fine standalone, and dies five seconds into a recording with

    ioctl(VIDIOC_STREAMON): Protocol error

Advertising a format is not the same as streaming it, so the agent must try another
one rather than abandon the camera.
"""
import importlib.machinery, importlib.util, os, tempfile

AGENT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                     "scripts", "thinclient-agent")
spec = importlib.util.spec_from_loader("tcagent", importlib.machinery.SourceFileLoader("tcagent", AGENT))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

tmp = tempfile.mkdtemp()
m.CAM_FORMAT_STATE = os.path.join(tmp, "cam-format")
m.conf_get = lambda k, d="": d            # no /etc/thinclient in the test
m._cap = lambda k, d="": d
REAL_PROBE = m._cam_probe_format      # kept: the ladder tests stub this out
ok = 0
def check(name, cond):
    global ok
    assert cond, "FAIL " + name
    ok += 1
    print("  PASS " + name)

# ---- the variant ladder ----------------------------------------------------------
m._cam_probe_format = lambda dev: "mjpeg"
v = m._cam_variants("/dev/video0")
check("the camera's own advertised format is tried first", v[0] == ("mjpeg", "640x480"))
check("then the other format, because advertising is not streaming", v[1] == ("yuyv422", "640x480"))
check("then no format pin at all", v[2] == ("", "640x480"))
check("and finally nothing pinned — whatever the driver will give", v[3] == ("", ""))

m._cam_probe_format = lambda dev: "yuyv422"
check("a YUYV-only camera tries MJPEG second, not YUYV twice",
      m._cam_variants("/dev/video0")[1][0] == "mjpeg")

# ---- an explicit setting is an instruction, not a hint ----------------------------
m._cap = lambda k, d="": "mjpeg" if k == "CAMERA_FORMAT" else d
check("an operator-pinned CAMERA_FORMAT is never second-guessed",
      m._cam_variants("/dev/video0") == [("mjpeg", "640x480")])
m._cap = lambda k, d="": d

# ---- the arguments actually handed to ffmpeg -------------------------------------
m._cam_probe_format = lambda dev: "mjpeg"
m._CAM_ATTEMPT = 0
a = m._cam_input("/dev/video0")
check("first attempt pins the advertised format and size",
      "-input_format" in a and a[a.index("-input_format") + 1] == "mjpeg"
      and a[a.index("-video_size") + 1] == "640x480")
m._CAM_ATTEMPT = 2
a = m._cam_input("/dev/video0")
check("the third attempt drops the format pin but keeps the size",
      "-input_format" not in a and "-video_size" in a)
m._CAM_ATTEMPT = 3
a = m._cam_input("/dev/video0")
check("the last attempt pins nothing", "-input_format" not in a and "-video_size" not in a)
check("every attempt still names the device and a frame rate",
      a[-1] == "/dev/video0" and "-framerate" in a)
m._CAM_ATTEMPT = 0

# ---- the cache must not confuse one camera with another --------------------------
# Swapping the webcam used to apply the old camera's format to the new one, because
# the learnt value was filed under "/dev/video0".
m._cam_probe_format = REAL_PROBE       # the ladder tests stubbed it; test the real one
m._CAM_FMT.clear()
m._cam_identity = lambda dev: "CAMERA-A"
m.subprocess_run_calls = []
class R:  # v4l2-ctl --list-formats says MJPG
    returncode = 0; stdout = "MJPG\n"
real_run = m.subprocess.run
m.subprocess.run = lambda *a, **k: R()
check("the format is learnt from the camera", m._cam_probe_format("/dev/video0") == "mjpeg")
saved = open(m.CAM_FORMAT_STATE).read().split()
check("and stored against that camera's identity, not the device node",
      saved[0] == "CAMERA-A" and saved[1] == "mjpeg")

m._CAM_FMT.clear()
m._cam_identity = lambda dev: "CAMERA-B"          # a different webcam, same /dev/video0
class R2:
    returncode = 0; stdout = "YUYV\n"
m.subprocess.run = lambda *a, **k: R2()
check("a DIFFERENT camera on the same node re-probes instead of inheriting",
      m._cam_probe_format("/dev/video0") == "yuyv422")

# a file written by an older build carries no identity and must not be trusted
m._CAM_FMT.clear()
open(m.CAM_FORMAT_STATE, "w").write("mjpeg\n")
m._cam_identity = lambda dev: "CAMERA-C"
check("a pre-upgrade cache file is ignored rather than believed",
      m._cam_probe_format("/dev/video0") == "yuyv422")
m.subprocess.run = real_run

# ---- finding the camera after it re-enumerates ------------------------------------
# Taken from the device: a webcam on a marginal USB connection dropped and came back
# four times in three seconds, after which it was /dev/video1 (its metadata stream on
# /dev/video2) and /dev/video0 was gone. The agent kept looking at /dev/video0 and
# recorded screen-only until somebody rebooted.
import types

def fake_v4l2(capture_nodes, metadata_nodes=()):
    """Stand in for v4l2-ctl --list-formats: capture nodes list pixel formats,
    metadata nodes list none — which is how the two are told apart."""
    def run(argv, **kw):
        node = argv[argv.index("-d") + 1] if "-d" in argv else ""
        r = types.SimpleNamespace(returncode=0, stdout="")
        if node in capture_nodes:
            r.stdout = "\tType: Video Capture\n\n\t[0]: 'MJPG' (Motion-JPEG, compressed)\n"
        elif node in metadata_nodes:
            r.stdout = "\tType: Metadata Capture\n"
        else:
            r.returncode = 1
        return r
    return run

def with_nodes(nodes, capture, metadata=()):
    m.glob.glob = lambda pat: list(nodes)
    m.os.path.exists = lambda p: p in nodes
    m.subprocess.run = fake_v4l2(capture, metadata)
    m._CAM_DEV["dev"], m._CAM_DEV["at"] = "", 0.0

real_exists, real_glob = m.os.path.exists, m.glob.glob
m.conf_get = lambda k, d="": d          # no CAMERA_DEVICE override

with_nodes(["/dev/video0", "/dev/video1"], capture=["/dev/video0"])
check("the ordinary case still finds /dev/video0", m._camera_device() == "/dev/video0")

with_nodes(["/dev/video1", "/dev/video2"], capture=["/dev/video1"], metadata=["/dev/video2"])
check("after re-enumeration it finds the camera on its NEW node",
      m._camera_device() == "/dev/video1")

with_nodes(["/dev/video1", "/dev/video2"], capture=["/dev/video2"], metadata=["/dev/video1"])
check("a metadata node is never mistaken for the camera",
      m._camera_device() == "/dev/video2")

with_nodes(["/dev/video2", "/dev/video10"], capture=["/dev/video2", "/dev/video10"])
check("nodes are ordered numerically, so video10 never beats video2",
      m._camera_device() == "/dev/video2")

with_nodes([], capture=[])
check("no camera at all reads as no camera, not as /dev/video0",
      m._camera_device() == "")

# v4l2-ctl missing entirely: fall back to the old assumption, but only if it is there
m._CAM_DEV["dev"], m._CAM_DEV["at"] = "", 0.0
m.glob.glob = lambda pat: ["/dev/video0"]
m.os.path.exists = lambda p: p == "/dev/video0"
def boom(*a, **k): raise FileNotFoundError("no v4l2-ctl")
m.subprocess.run = boom
check("without v4l2-ctl it falls back to /dev/video0 when that exists",
      m._camera_device() == "/dev/video0")
m._CAM_DEV["dev"], m._CAM_DEV["at"] = "", 0.0
m.os.path.exists = lambda p: False
check("...and to nothing when it does not", m._camera_device() == "")

# an explicit setting is an instruction
m.conf_get = lambda k, d="": "/dev/video7" if k == "CAMERA_DEVICE" else d
check("an operator-set CAMERA_DEVICE is used verbatim, no probing",
      m._camera_device() == "/dev/video7")
m.conf_get = lambda k, d="": d

# the cached node is dropped the moment it stops existing
with_nodes(["/dev/video0"], capture=["/dev/video0"])
check("a node is cached once found", m._camera_device() == "/dev/video0")
with_nodes(["/dev/video1"], capture=["/dev/video1"])
m._CAM_DEV["dev"], m._CAM_DEV["at"] = "/dev/video0", m.time.time()   # cache says the old one
check("a cached node that has vanished is re-probed, not trusted",
      m._camera_device() == "/dev/video1")

m.os.path.exists, m.glob.glob = real_exists, real_glob

# --- a camera whose formats could not be read ------------------------------------
#
# The probe fails with "Device or resource busy" whenever ffmpeg already holds the
# camera, which is every time a recording restarts. It used to answer "mjpeg" anyway.
# On a YUYV-only camera that guess does not FAIL — ffmpeg opens the device and then
# spins at ~99% CPU producing nothing, with an empty stderr, so no failure is ever
# detected and no format rotation happens. Sia ran 57 minutes like that on 23 Sep and
# produced a 176-byte recording, screen included: one ffmpeg serves both outputs.
m.conf_get = lambda k, d="": d
m._CAM_FMT.clear()
# And the PERSISTED format too. Earlier cases left "CAMERA-C yuyv422" on disk, and that
# file is deliberately authoritative — it exists so a probe that cannot run (because the
# recorder is holding the camera) still gets the right answer. This case is specifically
# a camera nothing has ever managed to read.
try: os.remove(m.CAM_FORMAT_STATE)
except OSError: pass

class _Fail:
    returncode = 1
    stdout = ""
_real_run = m.subprocess.run
m.subprocess.run = lambda *a, **k: _Fail()
m.os.path.exists = lambda p: False          # skip the sysfs shortcut, force the v4l2-ctl path
# REAL_PROBE, not m._cam_probe_format: the ladder tests above replaced that name with a
# stub and never put it back, so calling it here would test the stub.
check("an unreadable camera pins NO format rather than guessing one",
      REAL_PROBE("/dev/video0") == "")
check("...and the guess is not remembered", "mjpeg" not in m._CAM_FMT.values())
m.subprocess.run = _real_run
m.os.path.exists = real_exists

m._cam_probe_format = lambda dev: ""
v = m._cam_variants("/dev/video0")
check("unpinned is tried first when the format is unknown", v[0] == ("", "640x480"))
check("then MJPEG explicitly", v[1] == ("mjpeg", "640x480"))
check("then YUYV explicitly — not a repeat of attempt one", v[2] == ("yuyv422", "640x480"))
check("and finally nothing pinned at all", v[3] == ("", ""))
check("every rotation slot is a DIFFERENT attempt", len({tuple(x) for x in v}) == len(v))

print("\n  %d passed" % ok)
