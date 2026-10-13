#!/usr/bin/env bash
# (selftest: may run during a game)
# x-dpi: the VM screen's size in pixels and millimetres as X reports it (programs work out the
# screen's DPI from these, Steam's overlay among them), Xft.dpi and the toolkit scale settings.
set -u
export DISPLAY=:1
echo "== xdpyinfo"; xdpyinfo 2>&1 | grep -E -i "dimensions|resolution|screen #" | head
echo "== xrandr"; xrandr 2>&1 | head -8
echo "== Xft.dpi (xrdb)"; xrdb -query 2>&1 | grep -i -E "dpi|scale" | head
echo "== environment of the newest gameoverlayui"
p=$(pgrep -n -f gameoverlayui); [ -n "$p" ] && tr '\0' '\n' < /proc/$p/environ 2>/dev/null | grep -E -i "dpi|scale|DISPLAY|STEAM_.*SCALE|GDK|QT_" | head -20
echo "== python: XDisplayWidthMM via Xlib"
python3 - <<'PY'
import ctypes, ctypes.util
x = ctypes.CDLL(ctypes.util.find_library("X11") or "libX11.so.6")
x.XOpenDisplay.restype = ctypes.c_void_p; x.XOpenDisplay.argtypes = [ctypes.c_char_p]
d = x.XOpenDisplay(b":1")
for f in ("XDisplayWidth", "XDisplayHeight", "XDisplayWidthMM", "XDisplayHeightMM"):
    getattr(x, f).argtypes = [ctypes.c_void_p, ctypes.c_int]
    print(f, getattr(x, f)(d, 0))
PY
