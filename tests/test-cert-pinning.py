"""Checking the Windows server's identity before the password leaves (plan item G1).

Runs a FAKE RDP server with its own self-signed certificate and checks the connect
window reads the right fingerprint, then walks every policy mode. The one that must
never regress: with pinning OFF, the connect window makes NO extra network connection.
"""
import hashlib, importlib.machinery, importlib.util, json, os, socket, ssl, struct
import subprocess, sys, tempfile, threading, types

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
os.environ["TC_CERT_SEEN"] = os.path.join(tmp, "cert-seen.json")

spec = importlib.util.spec_from_loader("tcconn", importlib.machinery.SourceFileLoader(
    "tcconn", os.path.join(ROOT, "scripts", "thinclient-connect")))
conn = importlib.util.module_from_spec(spec); spec.loader.exec_module(conn)
sp = conn.secpolicy()

ok = 0
def check(name, cond):
    global ok
    assert cond, "FAIL " + name
    ok += 1
    print("  PASS " + name)

# --- a fake RDP server ----------------------------------------------------------
key, crt = os.path.join(tmp, "k.pem"), os.path.join(tmp, "c.pem")
subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key,
                "-out", crt, "-days", "1", "-subj", "/CN=fake-rdp"], check=True, capture_output=True)
with open(crt) as f:
    der = ssl.PEM_cert_to_DER_cert(f.read())
REAL_FP = hashlib.sha256(der).hexdigest()

connections = []
def serve(sock, selected):
    sctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); sctx.load_cert_chain(crt, key)
    while True:
        try:
            c, _ = sock.accept()
        except OSError:
            return
        connections.append(1)
        try:
            c.recv(19)
            # TPKT + X.224 Connection Confirm + RDP_NEG_RSP(selectedProtocol)
            neg = struct.pack("<BBHI", 0x02, 0x00, 8, selected)
            cc = bytes([0x0e, 0xd0, 0, 0, 0x12, 0x34, 0]) + neg
            c.sendall(struct.pack(">BBH", 3, 0, 4 + len(cc)) + cc)
            if selected:
                with sctx.wrap_socket(c, server_side=True) as t:
                    t.recv(1)
        except (OSError, ssl.SSLError):
            pass
        finally:
            c.close()

def fake_server(selected=1):
    s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(5)
    threading.Thread(target=serve, args=(s, selected), daemon=True).start()
    return s.getsockname()[1]

TLS_PORT = fake_server(1)       # "TLS" like a normal Windows server
LEGACY_PORT = fake_server(0)    # ancient "RDP security": no certificate exists

def set_policy(mode, pins=None):
    sp.save({"cert_pin": mode, "cert_pins": pins or {}}, os.environ["TC_SEC_POLICY"])

def seen():
    with open(os.environ["TC_CERT_SEEN"]) as f:
        return json.load(f)

print("== reading the certificate ==")
fp, err = conn.rdp_cert_fingerprint("127.0.0.1", TLS_PORT)
check("the fingerprint read over RDP matches the server's real certificate", fp == REAL_FP and err is None)
check("a legacy server with no TLS is reported as such, not guessed",
      conn.rdp_cert_fingerprint("127.0.0.1", LEGACY_PORT) == (None, "no-tls"))
dead = socket.socket(); dead.bind(("127.0.0.1", 0)); dead_port = dead.getsockname()[1]; dead.close()
check("nothing listening reports unreachable, quickly",
      conn.rdp_cert_fingerprint("127.0.0.1", dead_port, timeout=2)[1] == "unreachable")

print("== pinning OFF (the default): exactly today's behaviour ==")
set_policy("off")
before = len(connections)
check("connecting is allowed", conn.server_identity_decision("127.0.0.1", TLS_PORT) == "allow")
check("THE GUARANTEE: no extra network connection at all", len(connections) == before)
check("nothing is recorded", not os.path.exists(os.environ["TC_CERT_SEEN"]))

print("== REPORT mode: learn, warn, never block ==")
set_policy("report")
check("first sight of a server: allowed", conn.server_identity_decision("127.0.0.1", TLS_PORT) == "allow")
key_ = "127.0.0.1:%d" % TLS_PORT
check("…and its fingerprint is recorded for the manager to learn",
      seen()[key_]["fp"] == REAL_FP and seen()[key_]["decision"] == "learn")
set_policy("report", {key_: ["ab" * 32]})
check("a DIFFERENT certificate is still allowed in report mode",
      conn.server_identity_decision("127.0.0.1", TLS_PORT) == "allow")
check("…but recorded as a warning", seen()[key_]["decision"] == "warn")
check("an unreachable server is allowed through (FreeRDP will fail on its own)",
      conn.server_identity_decision("127.0.0.1", dead_port) == "allow")

print("== ENFORCE mode ==")
set_policy("enforce", {key_: [REAL_FP]})
check("the right server is allowed", conn.server_identity_decision("127.0.0.1", TLS_PORT) == "allow")
set_policy("enforce", {key_: ["ab" * 32]})
v = conn.server_identity_decision("127.0.0.1", TLS_PORT)
check("THE ATTACK: a server with another certificate is REFUSED", v != "allow" and "not sent" in v)
check("the refusal is recorded for the manager to alert on", seen()[key_]["decision"] == "refuse")
set_policy("enforce", {})
check("enforce, no pin yet: learned and allowed (first contact)",
      conn.server_identity_decision("127.0.0.1", TLS_PORT) == "allow")
v = conn.server_identity_decision("127.0.0.1", LEGACY_PORT)
check("enforce: a server whose identity can't be checked is refused", v != "allow")

print("== a missing policy module never stops anyone connecting ==")
conn._SECPOL = False
check("module unavailable -> allow", conn.server_identity_decision("127.0.0.1", TLS_PORT) == "allow")

print("\n  %d passed" % ok)
