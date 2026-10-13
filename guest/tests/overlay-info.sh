#!/usr/bin/env bash
# (selftest: may run during a game)
# overlay-info: how Steam's in-game overlay draws in x86 games here. Its two x86 parts
# (ubuntu12_64/gameoverlayrenderer.so and steamoverlayvulkanlayer.so, which this bottle's
# present layer hosts), their sizes and builds, the overlay's shared memory, the settings
# strings its Vulkan layer looks for, and the shaders it draws with (SPIR-V, base64 between
# markers, for spirv-dis on the other side).
set -u
S=~/.local/share/Steam
echo "== $(date)"
for f in "$S/ubuntu12_64/gameoverlayrenderer.so" "$S/ubuntu12_64/steamoverlayvulkanlayer.so" \
         "$S/ubuntu12_64/steamoverlay_x86_64.json" "$S/steamrtarm64/gameoverlayui" ; do
  [[ -e "$f" ]] && ls -l "$f" && md5sum "$f" | cut -c1-32
done
echo "== shared memory (not FEX's)"
ls -la /dev/shm | grep -v ' fex-[0-9]*-stats$' | head -40
echo "== overlay processes"
ps -eo pid,etime,args | grep -E '[g]ameoverlayui' | cut -c1-200
python3 - "$S/ubuntu12_64/steamoverlayvulkanlayer.so" "$S/ubuntu12_64/gameoverlayrenderer.so" <<'PYEOF'
import base64, re, struct, sys
for path in sys.argv[1:]:
    try:
        data = open(path, "rb").read()
    except OSError as e:
        print("== can't read", path, e); continue
    print(f"== {path}: {len(data)} bytes")
    # settings and diagnostics it looks for
    strs = set(m.group().decode() for m in re.finditer(rb"[\x20-\x7e]{6,}", data))
    keys = sorted(s for s in strs if re.search(r"STEAM_|VK_LAYER|ENABLE_|DISABLE_|_DEBUG|Overlay.*(size|Size|scale|Scale|texture|Texture|shm|Shm)", s))
    print("-- strings of interest (%d)" % len(keys))
    for s in keys[:150]:
        print("  ", s[:200])
    # SPIR-V modules (magic 0x07230203), each up to its last OpFunctionEnd
    n = 0
    for m in re.finditer(re.escape(struct.pack("<I", 0x07230203)), data):
        off = m.start()
        if off % 4: continue
        pos = off + 20; last_end = None
        while pos + 4 <= len(data):
            w = struct.unpack_from("<I", data, pos)[0]
            wc, op = w >> 16, w & 0xffff
            if wc == 0 or op > 7000 or pos + wc * 4 > len(data): break
            if op == 56: last_end = pos + 4      # OpFunctionEnd
            pos += wc * 4
        if not last_end: continue
        blob = data[off:last_end]
        n += 1
        print(f"==SPIRV-BEGIN== {path.rsplit('/',1)[-1]} #{n} at 0x{off:x}, {len(blob)} bytes")
        print(base64.b64encode(blob).decode())
        print("==SPIRV-END==")
    print(f"-- {n} shaders")
PYEOF
