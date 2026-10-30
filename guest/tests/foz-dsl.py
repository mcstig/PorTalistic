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
    tag = int(n[:16], 16) if re.match(r"[0-9a-f]{16}", n) else -1
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
h0 = next(iter(found)); print(json.dumps(found[h0])[:1500])
