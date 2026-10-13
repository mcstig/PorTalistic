#!/usr/bin/env bash
# (selftest: may run during a game)
# perfmon-mem: reads (never writes) the running Steam overlay UI's memory to see how it sized the
# performance monitor: every text label of the monitor (CPerfLabel: its text, the scale it was
# measured at, its measured width and height) and the banner's settings (scales, corner, level).
# Offsets are for gameoverlayui.so md5 4d30f9c5... (Oct 11); other builds print a warning.
set -u
python3 - <<'PY'
import os, re, struct, subprocess, hashlib
pids = subprocess.run(["pgrep", "-f", "steamrtarm64/gameoverlayui"], capture_output=True, text=True).stdout.split()
VT = {"CPerfLabel": 0x70fb10, "CIngameFPSBanner": 0x7110d0, "CIngameFPSGraph": 0x7062d0}
NAMES = dict(VT, CIngameFPSGameFPS=None, CIngameFPSPresentationFPS=None, CIngameFPSCPUInfo=None,
             CIngameFPSGPUInfo=None, CIngameFPSRAMInfo=None, CIngameCPUCoreGraph=None)
for pid in pids:
    try:
        maps = open(f"/proc/{pid}/maps").read().splitlines()
    except Exception as e:
        print(pid, "maps:", e); continue
    base = None; path = None
    for l in maps:
        if l.endswith("/gameoverlayui.so"):
            a, b = [int(x, 16) for x in l.split()[0].split("-")]
            off = int(l.split()[2], 16)
            if off == 0 and base is None: base = a; path = l.split()[-1]
    print(f"== pid {pid}: {open(f'/proc/{pid}/cmdline').read().replace(chr(0),' ')[:120]}")
    if base is None: print("no gameoverlayui.so mapped"); continue
    try:
        md5 = hashlib.md5(open(path, "rb").read()).hexdigest()
    except Exception:
        md5 = "?"
    print(f"   gameoverlayui.so at {base:#x} md5 {md5}" + ("" if md5.startswith("4d30f9c5") else "  (WARNING: other build, offsets may be wrong)"))
    try:
        mem = open(f"/proc/{pid}/mem", "rb", 0)
    except Exception as e:
        print("   mem:", e); continue
    want = {struct.pack("<Q", base + v): k for k, v in VT.items()}
    found = {k: [] for k in VT}
    for l in maps:
        f = l.split()
        if len(f) < 5 or not f[1].startswith("rw"): continue
        if len(f) >= 6 and f[5].startswith("/") and not f[5].endswith("]"): continue
        a, b = [int(x, 16) for x in f[0].split("-")]
        if b - a > 1 << 30: continue
        try:
            mem.seek(a); data = mem.read(b - a)
        except Exception:
            continue
        for pat, k in want.items():
            i = data.find(pat)
            while i >= 0:
                if i % 8 == 0: found[k].append(a + i)
                i = data.find(pat, i + 8)
    def rd(addr, n):
        try:
            mem.seek(addr); return mem.read(n)
        except Exception:
            return b""
    for o in found["CIngameFPSBanner"]:
        d = rd(o, 640)
        if len(d) < 640: continue
        f580, f584 = struct.unpack_from("<ff", d, 580)
        corner, level = struct.unpack_from("<ii", d, 600)
        f612, f616 = struct.unpack_from("<ff", d, 612)
        print(f"   banner {o:#x}: user scale {f580:g}, screen scale {f584:g}, corner {corner}, level {level}, "
              f"saturation/opacity {f612:g}/{f616:g}, flags {d[568]} {d[569]} {d[570]} {d[571]}, size? {struct.unpack_from('<ii', d, 572)}")
        print("     raw 560..624:", " ".join(f"{x:08x}" for x in struct.unpack_from("<16I", d, 560)))
        cpu = struct.unpack_from("<Q", d, 544)[0]
        if cpu > 0x10000:
            core = struct.unpack_from("<Q", rd(cpu + 568, 8) or b"\0" * 8, 0)[0]
            if core > 0x10000:
                c = rd(core, 600)
                cv = struct.unpack_from("<Q", c, 0)[0]
                print(f"     CPU core graph {core:#x} (vtable {cv - base:#x}): height setting {struct.unpack_from('<i', c, 532)[0]}")
        for off in range(512, 568, 8):
            q = struct.unpack_from("<Q", d, off)[0]
            v = struct.unpack_from("<Q", rd(q, 8) or b"\0" * 8, 0)[0] if q > 0x10000 else 0
            k = next((n for n, a in VT.items() if a + base == v), hex(v - base) if v > base else hex(v))
            extra = ""
            if q > 0x10000:
                c = rd(q, 600)
                if len(c) == 600:
                    extra = " ints@548..560: " + " ".join(str(x) for x in struct.unpack_from("<4i", c, 548))
            print(f"     +{off}: {q:#x} -> {k}{extra}")
    for o in found["CIngameFPSGraph"]:
        d = rd(o, 600)
        if len(d) < 600: continue
        print(f"   graph {o:#x}: tall setting {struct.unpack_from('<i', d, 548)[0]}, number {struct.unpack_from('<i', d, 556)[0]}")
    print(f"   {len(found['CPerfLabel'])} labels")
    for o in found["CPerfLabel"][:80]:
        d = rd(o, 1100)
        if len(d) < 1100: continue
        txt = d[0x20c:0x20c + 4 * 40]
        s = ""
        for j in range(0, len(txt), 4):
            c = struct.unpack_from("<I", txt, j)[0]
            if c == 0: break
            s += chr(c) if c < 0x110000 else "?"
        sc, w, h = struct.unpack_from("<fii", d, 1036)
        print(f"   label {o:#x}: text {s!r:24} measured at scale {sc:g}: {w} x {h}")
PY
