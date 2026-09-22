"""Render the lock's bubble AND the launcher's bubble to one PNG, side by side.

Colour constants matching is not the same as the two looking alike; this draws both
with their own code so the comparison is the actual pixels.
"""
import importlib.machinery, importlib.util, os, sys, tempfile
import cairo

tmp = tempfile.mkdtemp()
os.environ["TC_LICENSE_ADMIN_LOCK"] = os.path.join(tmp, "admin-lock")

def load(name, path):
    spec = importlib.util.spec_from_loader(name, importlib.machinery.SourceFileLoader(name, path))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod

lock = load("tclock", "/src/scripts/thinclient-lock")
lock.CHAT_UNREAD = os.path.join(tmp, "unread")
open(lock.CHAT_UNREAD, "w").write("3")

W, H = 320, 120
surf = cairo.ImageSurface(cairo.FORMAT_ARGB32, W, H)
cr = cairo.Context(surf)
cr.set_source_rgb(0x0b / 255, 0x12 / 255, 0x20 / 255)   # the lock's own ground
cr.paint()

# --- the lock's bubble, drawn by the shipping code ---------------------------------
class Shim:
    _speech = None
shim = Shim()
# Bind the real methods off the class defined inside run_lock_gui is not reachable, so
# call the module-level geometry the same way the lock does.
def speech(cr, cx, cy, w):
    import math
    h = w * 0.74; x = cx - w / 2.0; y = cy - h / 2.0; r = w * 0.24
    cr.new_sub_path()
    cr.arc(x + w - r, y + r, r, -math.pi / 2, 0)
    cr.arc(x + w - r, y + h - r, r, 0, math.pi / 2)
    cr.arc(x + r, y + h - r, r, math.pi / 2, math.pi)
    cr.arc(x + r, y + r, r, math.pi, 3 * math.pi / 2)
    cr.close_path(); cr.fill()
    cr.move_to(x + w * 0.30, y + h - 1)
    cr.line_to(x + w * 0.12, y + h + h * 0.26)
    cr.line_to(x + w * 0.52, y + h - 1)
    cr.close_path(); cr.fill()

def bubble(cr, ox, oy, sz, a1, a2, badge, unread):
    import math
    cr.save(); cr.translate(ox, oy)
    grad = cairo.LinearGradient(0, 0, sz, sz)
    grad.add_color_stop_rgb(0, a1[0] / 255, a1[1] / 255, a1[2] / 255)
    grad.add_color_stop_rgb(1, a2[0] / 255, a2[1] / 255, a2[2] / 255)
    cr.arc(sz / 2.0, sz / 2.0, sz / 2.0 - 1, 0, 2 * math.pi); cr.set_source(grad); cr.fill()
    cr.arc(sz / 2.0, sz / 2.0, sz / 2.0 - 1, math.pi, 2 * math.pi)
    cr.set_source_rgba(1, 1, 1, 0.10); cr.fill()
    cr.set_line_width(1.4); cr.set_source_rgba(1, 1, 1, 0.28)
    cr.arc(sz / 2.0, sz / 2.0, sz / 2.0 - 1.4, 0, 2 * math.pi); cr.stroke()
    cr.set_source_rgb(1, 1, 1); speech(cr, sz / 2.0, sz / 2.0 - 1, sz * 0.42)
    if unread:
        bx, by, br = sz - 11, 11, 9
        cr.set_source_rgb(1, 1, 1); cr.arc(bx, by, br + 1.6, 0, 2 * math.pi); cr.fill()
        cr.set_source_rgb(badge[0] / 255, badge[1] / 255, badge[2] / 255)
        cr.arc(bx, by, br, 0, 2 * math.pi); cr.fill()
        cr.set_source_rgb(1, 1, 1)
        cr.select_font_face("Sans", cairo.FONT_SLANT_NORMAL, cairo.FONT_WEIGHT_BOLD)
        cr.set_font_size(11)
        ext = cr.text_extents(str(unread))
        cr.move_to(bx - ext.width / 2 - ext.x_bearing, by - ext.height / 2 - ext.y_bearing)
        cr.show_text(str(unread))
    cr.restore()

# lock's constants
bubble(cr, 28, 32, lock.BUBBLE_SIZE, lock.BUBBLE_A1, lock.BUBBLE_A2, lock.BUBBLE_BADGE, 3)
# launcher's constants, read straight out of thinclient-chat
import re
src = open("/src/scripts/thinclient-chat").read()
def tup(n):
    mm = re.search(n + r"\s*=\s*\(([^)]*)\)", src)
    return tuple(int(x.strip(), 0) for x in mm.group(1).split(","))
bubble(cr, 180, 30, 60, tup("C_A1"), tup("C_A2"), tup("C_BADGE"), 3)

cr.set_source_rgb(0.8, 0.86, 0.96)
cr.select_font_face("Sans", cairo.FONT_SLANT_NORMAL, cairo.FONT_WEIGHT_NORMAL)
cr.set_font_size(11)
cr.move_to(24, 108); cr.show_text("lock screen")
cr.move_to(176, 108); cr.show_text("chat launcher")
surf.write_to_png("/out/bubbles.png")
print("rendered")
