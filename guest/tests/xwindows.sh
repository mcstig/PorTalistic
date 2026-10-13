#!/usr/bin/env bash
# (selftest: may run during a game)
# xwindows: the VM screen's (X display :1) window tree: each window's size and place, whether
# it's shown, its title and process. Steam's overlay lays itself out by the size of the window a
# game's Vulkan surface belongs to, so a window of the wrong size here shows as an overlay
# drawn in the wrong place or stretched.
set -u
python3 - <<'PYEOF'
import ctypes, ctypes.util, os, sys
x = ctypes.CDLL(ctypes.util.find_library("X11") or "libX11.so.6")
x.XOpenDisplay.restype = ctypes.c_void_p; x.XOpenDisplay.argtypes = [ctypes.c_char_p]
x.XDefaultRootWindow.restype = ctypes.c_ulong; x.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
x.XQueryTree.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_ulong),
                         ctypes.POINTER(ctypes.POINTER(ctypes.c_ulong)), ctypes.POINTER(ctypes.c_uint)]
x.XGetGeometry.argtypes = [ctypes.c_void_p, ctypes.c_ulong] + [ctypes.c_void_p] * 7
x.XFree.argtypes = [ctypes.c_void_p]
x.XInternAtom.restype = ctypes.c_ulong; x.XInternAtom.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
x.XGetWindowProperty.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_long, ctypes.c_long, ctypes.c_int,
                                 ctypes.c_ulong, ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_int),
                                 ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_void_p)]

class XWA(ctypes.Structure):
    _fields_ = [("x", ctypes.c_int), ("y", ctypes.c_int), ("width", ctypes.c_int), ("height", ctypes.c_int),
                ("border_width", ctypes.c_int), ("depth", ctypes.c_int), ("visual", ctypes.c_void_p),
                ("root", ctypes.c_ulong), ("class", ctypes.c_int), ("bit_gravity", ctypes.c_int),
                ("win_gravity", ctypes.c_int), ("backing_store", ctypes.c_int), ("backing_planes", ctypes.c_ulong),
                ("backing_pixel", ctypes.c_ulong), ("save_under", ctypes.c_int), ("colormap", ctypes.c_ulong),
                ("map_installed", ctypes.c_int), ("map_state", ctypes.c_int), ("all_event_masks", ctypes.c_long),
                ("your_event_mask", ctypes.c_long), ("do_not_propagate_mask", ctypes.c_long),
                ("override_redirect", ctypes.c_int), ("screen", ctypes.c_void_p)]
x.XGetWindowAttributes.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.POINTER(XWA)]
x.XSetErrorHandler.restype = ctypes.c_void_p
ERRH = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p)
_keep = ERRH(lambda d, e: 0); x.XSetErrorHandler(_keep)      # windows can vanish while we look

d = x.XOpenDisplay(os.environ.get("SHOT_DISPLAY", ":1").encode())
if not d: sys.exit("can't open display :1")
A = lambda n: x.XInternAtom(d, n, 0)
NAME, UTF8, PID = A(b"_NET_WM_NAME"), A(b"UTF8_STRING"), A(b"_NET_WM_PID")
WMNAME, STRING, CARD = A(b"WM_NAME"), A(b"STRING"), A(b"CARDINAL")

def prop(w, atom, typ, fmt_int=False):
    at = ctypes.c_ulong(); af = ctypes.c_int(); n = ctypes.c_ulong(); left = ctypes.c_ulong(); data = ctypes.c_void_p()
    if x.XGetWindowProperty(d, w, atom, 0, 256, 0, typ, ctypes.byref(at), ctypes.byref(af), ctypes.byref(n),
                            ctypes.byref(left), ctypes.byref(data)) != 0 or not data.value:
        return None
    try:
        if fmt_int:
            return ctypes.cast(data, ctypes.POINTER(ctypes.c_long))[0] if n.value else None
        return ctypes.string_at(data, n.value).decode("utf-8", "replace")
    finally:
        x.XFree(data)

states = {0: "hidden", 1: "unviewable", 2: "shown"}
def walk(w, depth):
    a = XWA()
    if not x.XGetWindowAttributes(d, w, ctypes.byref(a)): return
    title = prop(w, NAME, UTF8) or prop(w, WMNAME, STRING) or ""
    pid = prop(w, PID, CARD, True)
    comm = ""
    if pid:
        try: comm = open(f"/proc/{pid}/comm").read().strip()
        except OSError: pass
    print(f"{'  ' * depth}0x{w:x} {a.width}x{a.height}+{a.x}+{a.y} {states.get(a.map_state, a.map_state)}"
          f"{' override' if a.override_redirect else ''}{' depth ' + str(a.depth) if a.depth not in (24, 0) else ''}"
          f"{' ' + repr(title[:60]) if title else ''}{f' pid {pid} {comm}' if pid else ''}")
    r = ctypes.c_ulong(); p = ctypes.c_ulong(); kids = ctypes.POINTER(ctypes.c_ulong)(); nk = ctypes.c_uint()
    if not x.XQueryTree(d, w, ctypes.byref(r), ctypes.byref(p), ctypes.byref(kids), ctypes.byref(nk)): return
    ks = [kids[i] for i in range(nk.value)]
    if kids: x.XFree(kids)
    for k in ks:
        # skip the many 1x1 helper windows nobody sees, but keep anything with a title or a process
        walk(k, depth + 1)

print("== X display :1 windows (size+x+y, state, title, process)")
walk(x.XDefaultRootWindow(d), 0)
PYEOF
