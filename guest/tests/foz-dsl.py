#!/usr/bin/env python3
# Prints the descriptor set layouts (from a Fossilize database) that fossilize_replay said this
# device doesn't support (hashes from its log). For CS2's "null descriptor set layout" (Oct 28).
import sys, zlib, json, re, collections
db, log = sys.argv[1], sys.argv[2]
want = set(re.findall(r"Descriptor set layout ([0-9a-f]{16}) is not supported", open(log, errors="replace").read()))
f = open(db, "rb"); head = f.read(16)
found = {}
while True:
    name = f.read(40)
    if len(name) < 40: break
    hdr = f.read(16)
    size, fmt, crc, usize = __import__("struct").unpack("<IIII", hdr)
    n = name.decode(errors="replace")
    # (Fossilize: the tag as 24 hex digits, then the 64-bit hash as 16; Nov 1: the tag was read from the
    # first 16 digits, always 0, so nothing matched)
    tag = int(n[:24], 16) if re.match(r"[0-9a-f]{40}", n) else -1
    h = n[24:40]
    if tag == 2 and h in want:
        data = f.read(size)
        if fmt != 1:
            try: data = zlib.decompress(data)
            except zlib.error: data = zlib.decompress(data, -15)
        found[h] = json.loads(data)
    else:
        f.seek(size, 1)
print("unsupported layouts:", len(want), "found:", len(found))
types = collections.Counter(); flags = collections.Counter(); big = []
for h, j in list(found.items()):
    d = j.get("setLayouts", {}).get(h) or next(iter(j.values()))
    if isinstance(d, dict) and "bindings" not in d: d = next(iter(d.values()))
    bs = d.get("bindings", [])
    for b in bs:
        types[(b.get("descriptorType"), b.get("descriptorCount"))] += 1
    flags[json.dumps({k: v for k, v in d.items() if k not in ("bindings",)})[:200]] += 1
for k, v in types.most_common(15): print("type,count", k, v)
for k, v in flags.most_common(6): print("layout fields", v, k)
if found:
    h0 = next(iter(found)); print(json.dumps(found[h0])[:1500])
# Nov 1: each refused layout in one line: flags, then type:count:bindingflags per binding
TN = {0: "SAMPLER", 1: "COMB", 2: "SAMPLED", 3: "STORAGE_IMG", 4: "UTB", 5: "STB", 6: "UBO", 7: "SSBO", 8: "UBO_DYN", 9: "SSBO_DYN", 10: "INPUT_ATT", 1000150000: "ACCEL", 1000138000: "INLINE_UB"}
for h, j in found.items():
    d = j["setLayouts"].get(h) or next(iter(j["setLayouts"].values()))
    bf = (d.get("pNext") or [{}])[0].get("bindingFlags", [])
    parts = []
    for i, b in enumerate(d.get("bindings", [])):
        parts.append("%s:%d:%s" % (TN.get(b["descriptorType"], b["descriptorType"]), b["descriptorCount"], bf[i] if i < len(bf) else 0))
    print("LAYOUT", h, "flags", d.get("flags", 0), " ".join(sorted(set(parts))))
# Nov 1: the stages each refused layout's bindings are for
ST = [(1,"VS"),(2,"TCS"),(4,"TES"),(8,"GS"),(16,"FS"),(32,"CS"),(64,"TASK"),(128,"MESH"),(256,"RGEN"),(512,"AHIT"),(1024,"CHIT"),(2048,"MISS"),(4096,"ISEC"),(8192,"CALL")]
sc = collections.Counter()
for h, j in found.items():
    d = j["setLayouts"].get(h) or next(iter(j["setLayouts"].values()))
    st = 0
    for b in d.get("bindings", []): st |= b.get("stageFlags", 0)
    sc["|".join(n for v, n in ST if st & v) or "none"] += 1
for k, v in sc.most_common(): print("STAGES", v, k)
