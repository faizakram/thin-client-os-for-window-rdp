#!/usr/bin/env python3
"""Drive the install wizard on screen (Xvfb) against tests/gtk/fake-installer.sh.
   python3 install-wizard.py ok|badmachine|fail  -> screenshots in $SHOTS (default /tmp/shots)"""
import json, os, sys, tempfile, importlib.machinery, importlib.util
mode = sys.argv[1] if len(sys.argv) > 1 else "ok"
here = os.path.dirname(os.path.abspath(__file__))
shots = os.environ.get("SHOTS", "/tmp/shots"); os.makedirs(shots, exist_ok=True)
lsblk = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
json.dump({"blockdevices": [
    {"name": "sda", "size": 32000000000, "model": "SanDisk Cruzer", "type": "disk", "tran": "usb", "ro": False},
    {"name": "nvme0n1", "size": 256060514304, "model": "KINGSTON SNV2S250G", "type": "disk", "tran": "nvme", "ro": False},
    {"name": "loop0", "size": 900000000, "model": None, "type": "loop", "tran": None, "ro": True},
    {"name": "sdb", "size": 64000000000, "model": "Generic USB", "type": "disk", "tran": "usb", "ro": False}]}, lsblk)
lsblk.close()
os.environ.update(TC_LSBLK_JSON=lsblk.name, TC_LIVE_DISK="sda", FAKE_MODE=mode,
                  FAKE_LOG=os.path.join(shots, "fake-%s.log" % mode),
                  TC_INSTALL_CMD=json.dumps([os.path.join(here, "fake-installer.sh")]))
src = os.environ.get("WIZARD", "/src/scripts/thinclient-install-gui")
loader = importlib.machinery.SourceFileLoader("wiz", src)
spec = importlib.util.spec_from_loader("wiz", loader); wiz = importlib.util.module_from_spec(spec); loader.exec_module(wiz)
from gi.repository import Gtk, GLib, Gdk

dialogs = []
dialog_buttons = []
# Run the REAL dialog, but answer it instead of blocking: record what a person sees.
def fake_run(d):
    d.show_all()
    while Gtk.events_pending(): Gtk.main_iteration()
    import time; t = time.time()
    while time.time() - t < 0.4: Gtk.main_iteration_do(False); time.sleep(0.01)
    dialogs.append(d.get_content_area().get_children()[0].get_text())
    for b in d.get_action_area().get_children():
        dialog_buttons.append((b.get_label(), b.get_mapped(), b.get_style_context().list_classes()))
    gw = d.get_window(); pb = Gdk.pixbuf_get_from_window(gw, 0, 0, gw.get_width(), gw.get_height())
    pb.savev(os.path.join(shots, "%s-dialog-%d.png" % (mode, len(dialogs))), "png", [])
    return Gtk.ResponseType.OK
Gtk.Dialog.run = fake_run
fails = []
def check(cond, what):
    print(("PASS " if cond else "FAIL ") + what); (None if cond else fails.append(what))
def shot(w, name):
    import time; t = time.time()
    while time.time() - t < 0.4:          # let the new page actually paint
        Gtk.main_iteration_do(False); time.sleep(0.01)
    gw = w.get_window(); pb = Gdk.pixbuf_get_from_window(gw, 0, 0, gw.get_width(), gw.get_height())
    pb.savev(os.path.join(shots, "%s-%s.png" % (mode, name)), "png", [])

w = wiz.Wizard()
def wait(cond, timeout=15):
    import time; t = time.time()
    while not cond() and time.time() - t < timeout:
        Gtk.main_iteration_do(False); time.sleep(0.02)
    return cond()

def script():
    wait(lambda: w.checks.get("_done"))
    shot(w, "1-check")
    check(w.encrypted_image, "image reported as encrypted")
    if mode == "badmachine":
        check(not w.btn_next.get_sensitive(), "Next is blocked when Secure Boot is off")
        row, icon, hint = w.check_rows["secureboot"]
        check(hint.get_mapped() and "Secure Boot" in hint.get_text(), "the BIOS fix is shown for Secure Boot")
        check(not w.check_rows["tpm"][2].get_mapped(), "no fix shown for a passing check")
        return finish()
    check(w.btn_next.get_sensitive(), "Next enabled when all checks pass")
    w._on_next(); wait(lambda: w.page == "disk"); shot(w, "2-disk")
    names = [d["name"] for d in w.disks]
    check("sda" not in names, "the live USB is not offered")
    check("loop0" not in names, "loop devices are not offered")
    check(names == ["nvme0n1", "sdb"], "disks listed: %s" % names)
    check(w.disk and w.disk["name"] == "nvme0n1", "the only internal disk is preselected")
    w._on_next(); wait(lambda: w.page == "name")
    check(not w.btn_next.get_sensitive(), "Install disabled with an empty name")
    w.name_entry.set_text("Reception-PC"); shot(w, "3-name")
    check(w.btn_next.get_sensitive() and w.btn_next.get_label() == "Install", "Install enabled with a name")
    w._on_next()
    check(dialogs and dialogs[-1].startswith("Erase"), "an erase confirmation was asked")
    styled = [(l, m, c) for l, m, c in dialog_buttons if any(x in c for x in ("primary", "secondary", "danger"))]
    check(len(dialog_buttons) == 2 and len(styled) == 2 and all(m for _, m, _ in dialog_buttons),
          "both erase-dialog buttons are styled and visible: %s" % [(l, c) for l, _, c in dialog_buttons])
    wait(lambda: w.otp_entry.get_mapped()); 
    check(w.code_lbl.get_mapped() and w.code_lbl.get_text() == "K7Q-4MX", "pairing code shown on screen")
    shot(w, "4-approval")
    w.otp_entry.set_text("999999"); w._send_otp()
    wait(lambda: w.otp_err.get_text() != "")
    check("not right" in w.otp_err.get_text() and w.otp_err.get_mapped(), "a wrong password shows the error")
    wait(lambda: w.otp_entry.get_sensitive()); shot(w, "4b-otp-error")
    w.otp_entry.set_text("123456"); w._send_otp()
    if mode == "fail":
        wait(lambda: w.page == "failed", 20); shot(w, "5-failed")
        check(w.page == "failed" and "partition table" in w.fail_lbl.get_text(), "failure message shown")
        check("partly written" in w.fail_safe.get_text(), "says the disk was touched")
        b = w.log_view.get_buffer()
        check("noise before the checks" in b.get_text(b.get_start_iter(), b.get_end_iter(), False),
              "the installer's own output is kept for the Details box")
        return finish()
    wait(lambda: w.current_stage == "copy"); wait(lambda: w.progress.get_fraction() > 0.3, 5)
    shot(w, "5-progress")
    check(w.progress.get_mapped() and w.progress.get_fraction() > 0.3, "copy progress bar moves (%.2f)" % w.progress.get_fraction())
    check(not w.approval_box.get_mapped(), "approval panel hidden once installing")
    check(not w.btn_cancel.get_sensitive(), "Cancel disabled once the disk is being written")
    wait(lambda: w.page == "done", 20); shot(w, "6-done")
    check(w.page == "done", "reached the Done screen")
    def texts(wd):
        out = []
        if isinstance(wd, Gtk.Label): out.append(wd.get_text())
        if isinstance(wd, Gtk.Container):
            for c in wd.get_children(): out += texts(c)
        return out
    t = " ".join(texts(w.done_steps))
    check(w.done_steps.get_mapped() and "3 minutes" in t and "THINCLIENT-ENROLL-ME.der" in t, "first-boot instructions shown")
    check(w.btn_next.get_label() == "Restart now", "Restart button offered")
    check(len(w.done_steps.get_children()) == 4, "four numbered steps on the Done screen")
    check(w.done_warn.get_mapped() and "switch it off" in " ".join(texts(w.done_warn)),
          "the do-not-switch-off warning is on screen")
    w._on_next()
    wait(lambda: "restart answer" in open(os.environ["FAKE_LOG"]).read(), 10)
    check("restart answer: reboot" in open(os.environ["FAKE_LOG"]).read(),
          "Restart asks the still-running installer to reboot")
    check(not w.btn_next.get_sensitive(), "Restart button disabled after the click")
    args = open(os.environ["FAKE_LOG"]).read()
    check("--disk /dev/nvme0n1 --confirm /dev/nvme0n1 --name Reception-PC" in args, "installer got the answers as options")
    check("999999" not in args and "123456" not in args, "the password never lands in an argument")
    finish()

def finish():
    print("RESULT:", "FAIL %d" % len(fails) if fails else "ALL PASS")
    os._exit(1 if fails else 0)

GLib.timeout_add(300, lambda: (script(), False)[1])
Gtk.main()
