#!/usr/bin/env bash
# (selftest: may run during a game)
# screenshot: what the VM's own screen (X display :1) shows right now, as a PNG in the kit's
# logs/ (via this test's output: the PNG goes to stdout base64-encoded between markers, and the
# Mac side saves it). Tells a picture problem in the game's rendering apart from one in getting
# the picture to the Mac window (the screen server's updates).
set -u
python3 - <<'PYEOF'
import base64, ctypes, ctypes.util, struct, sys, zlib

x = ctypes.CDLL(ctypes.util.find_library("X11") or "libX11.so.6")

class XImage(ctypes.Structure):
    _fields_ = [("width", ctypes.c_int), ("height", ctypes.c_int), ("xoffset", ctypes.c_int),
                ("format", ctypes.c_int), ("data", ctypes.POINTER(ctypes.c_ubyte)),
                ("byte_order", ctypes.c_int), ("bitmap_unit", ctypes.c_int),
                ("bitmap_bit_order", ctypes.c_int), ("bitmap_pad", ctypes.c_int),
                ("depth", ctypes.c_int), ("bytes_per_line", ctypes.c_int),
                ("bits_per_pixel", ctypes.c_int), ("red_mask", ctypes.c_ulong),
                ("green_mask", ctypes.c_ulong), ("blue_mask", ctypes.c_ulong)]

x.XOpenDisplay.restype = ctypes.c_void_p
x.XOpenDisplay.argtypes = [ctypes.c_char_p]
x.XDefaultRootWindow.restype = ctypes.c_ulong
x.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
x.XGetImage.restype = ctypes.POINTER(XImage)
x.XGetImage.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_int,
                        ctypes.c_uint, ctypes.c_uint, ctypes.c_ulong, ctypes.c_int]
x.XGetGeometry.argtypes = [ctypes.c_void_p, ctypes.c_ulong] + [ctypes.c_void_p] * 7

import os
d = x.XOpenDisplay(os.environ.get("SHOT_DISPLAY", ":1").encode())
if not d:
    sys.exit("can't open display :1")
root = x.XDefaultRootWindow(d)
if os.environ.get("SHOT_WINDOW"):          # one window instead of the whole screen (window-shot)
    root = int(os.environ["SHOT_WINDOW"], 16)
r = ctypes.c_ulong(); xx = ctypes.c_int(); yy = ctypes.c_int()
w = ctypes.c_uint(); h = ctypes.c_uint(); bw = ctypes.c_uint(); dp = ctypes.c_uint()
x.XGetGeometry(d, root, ctypes.byref(r), ctypes.byref(xx), ctypes.byref(yy),
               ctypes.byref(w), ctypes.byref(h), ctypes.byref(bw), ctypes.byref(dp))
img = x.XGetImage(d, root, 0, 0, w.value, h.value, 0xFFFFFFFF, 2).contents   # ZPixmap
W, H, bpl = img.width, img.height, img.bytes_per_line
if img.bits_per_pixel != 32:
    sys.exit(f"unexpected {img.bits_per_pixel} bits per pixel")
raw = ctypes.string_at(img.data, bpl * H)
rows = []
for y in range(H):
    line = raw[y * bpl:y * bpl + W * 4]
    rgb = bytearray(W * 3)
    rgb[0::3] = line[2::4]; rgb[1::3] = line[1::4]; rgb[2::3] = line[0::4]   # BGRX -> RGB
    rows.append(b"\x00" + bytes(rgb))
def chunk(t, b):
    return struct.pack(">I", len(b)) + t + b + struct.pack(">I", zlib.crc32(t + b) & 0xffffffff)
png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0))
       + chunk(b"IDAT", zlib.compress(b"".join(rows), 6)) + chunk(b"IEND", b""))
print(f"== {os.environ.get('SHOT_WINDOW') or 'screen'} :1, {W}x{H}")
print("==PNG-BEGIN==")
print(base64.b64encode(png).decode())
print("==PNG-END==")
PYEOF
