#!/usr/bin/env bash
# (selftest: may run during a game)
# exe-bytes: code bytes around given addresses (RVAs) of a game's .exe, to read the instructions
# where a crash report says it crashed. Default: Stellar Blade Demo's SB-Win64-Shipping.exe.
set -u
EXE="${BOTTLE_TEST_EXE:-$HOME/.local/share/Steam/steamapps/common/StellarBladeDemo/SB/Binaries/Win64/SB-Win64-Shipping.exe}"
RVAS="${BOTTLE_TEST_RVAS:-0x28f9bb8 0x290dff1 0x29551e6 0x28c4b05 0x296005f 0x28e3bd7}"
python3 - "$EXE" $RVAS <<'PY'
import struct, sys
path, rvas = sys.argv[1], [int(x, 16) for x in sys.argv[2:]]
f = open(path, "rb")
h = f.read(4096)
pe = struct.unpack_from("<I", h, 0x3c)[0]
nsec = struct.unpack_from("<H", h, pe + 6)[0]
optsz = struct.unpack_from("<H", h, pe + 20)[0]
secs = []
for i in range(nsec):
    o = pe + 24 + optsz + 40 * i
    name = h[o:o + 8].rstrip(b"\0").decode(errors="replace")
    vsize, va, rsize, raw = struct.unpack_from("<IIII", h, o + 8)
    secs.append((name, va, vsize, raw, rsize))
print("sections:", [(s[0], hex(s[1]), hex(s[2])) for s in secs])
for rva in rvas:
    for name, va, vsize, raw, rsize in secs:
        if va <= rva < va + vsize:
            start = max(va, rva - 0x300)
            f.seek(raw + start - va)
            data = f.read(rva - start + 0x80)
            print(f"==CODE {rva:#x} from {start:#x} {name}")
            print(data.hex())
            break
PY
