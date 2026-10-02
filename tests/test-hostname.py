"""Device hostname (security plan item 9): devices installed without a name no longer
announce the image's default name on customer networks — without ever leaving the
machine unable to look up its own name between the change and the restart."""
import importlib.machinery, importlib.util, os, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
spec = importlib.util.spec_from_loader("tcagent", importlib.machinery.SourceFileLoader(
    "tcagent", os.path.join(ROOT, "scripts", "thinclient-agent")))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

ok = 0
def check(name, cond):
    global ok
    assert cond, "FAIL " + name
    ok += 1
    print("  PASS " + name)

print("== the installer's naming rule ==")
check("device name -> hostname exactly as the installer makes it", m.canonical_hostname("Riana Rose - SA") == "Riana-Rose---SA")
check("no device name -> 'thinclient'", m.canonical_hostname("") == "thinclient")
check("unusable characters dropped", m.canonical_hostname("Café #1") == "Caf-1")
check("capped at 63 characters", len(m.canonical_hostname("x" * 100)) == 63)

def sandbox(running, hostname_file, hosts, device_name=""):
    d = tempfile.mkdtemp()
    m.HOSTNAME_FILE = os.path.join(d, "hostname"); open(m.HOSTNAME_FILE, "w").write(hostname_file + "\n")
    m.HOSTS_FILE = os.path.join(d, "hosts"); open(m.HOSTS_FILE, "w").write(hosts)
    m.HOSTNAME_RENAME_STATE = os.path.join(d, "renamed-from")
    m._hostname = lambda: running
    m.conf_get = lambda k, default="": device_name if k == "DEVICE_NAME" else default
    return d

OLD = "oldimgname"      # stands in for the image's former default hostname
HOSTS = "127.0.0.1   localhost %s\n::1 localhost ip6-localhost\n# a comment\n10.0.0.5 rdp-server\n" % OLD

print("== an unnamed device: phase 1 (before the restart) ==")
sandbox(OLD, OLD, HOSTS)
m.apply_hostname()
check("the new name is written for the next boot", open(m.HOSTNAME_FILE).read().strip() == "thinclient")
h = open(m.HOSTS_FILE).read()
check("BOTH names resolve until the restart (no stalled lookups)", OLD in h and "thinclient" in h)
check("unrelated host entries untouched", "10.0.0.5 rdp-server" in h and "# a comment" in h)
check("IPv6 line untouched", "::1 localhost ip6-localhost" in h)
before = open(m.HOSTS_FILE).read(); m.apply_hostname()
check("running again before the restart changes nothing", open(m.HOSTS_FILE).read() == before)

print("== phase 2 (after the restart) ==")
m._hostname = lambda: "thinclient"
m.apply_hostname()
h = open(m.HOSTS_FILE).read()
check("the old name is retired from /etc/hosts", OLD not in h)
check("the new name and localhost stay", "localhost" in h and "thinclient" in h)
check("the rename is finished (no state left)", not os.path.exists(m.HOSTNAME_RENAME_STATE))

print("== a device named at install time is left alone ==")
named_hosts = "127.0.0.1\tlocalhost\n127.0.1.1\tRiana-Rose---SA\n"
sandbox("Riana-Rose---SA", "Riana-Rose---SA", named_hosts, device_name="Riana Rose - SA")
m.apply_hostname()
check("hostname unchanged", open(m.HOSTNAME_FILE).read().strip() == "Riana-Rose---SA")
check("/etc/hosts unchanged", open(m.HOSTS_FILE).read() == named_hosts)

print("\n  %d passed" % ok)
