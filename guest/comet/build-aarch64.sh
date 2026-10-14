#!/bin/bash
# Builds Comet (the open-source stand-in for the GOG Galaxy client's background service) for the VM,
# from the pinned source, and writes the kit's copy into this folder (or the folder you name):
#   comet-aarch64, MANIFEST, BUILT, CRATES.tsv, THIRD-PARTY-LICENSES.txt, LICENSE-comet, LICENSE-proto-cc0
#
# Run it on an arm64 Linux that has git, cargo and rustc and can reach github.com and crates.io:
# the development VM (sudo dnf install -y rust cargo git; remove them again afterwards: the VMs
# Portalistic ships have no compilers). The packaged app never builds it; package-app.sh checks that
# the file in the kit matches MANIFEST.
#
# To move to another Comet version: change the three values below, run this, read BUILT, test.
set -euo pipefail
REPO=https://github.com/imLinguin/comet.git
TAG=v0.3.2
COMMIT=3d7488ee72f83b7e8462a70fd4c4638d6da71360     # what the tag must point at
PROTO_COMMIT=923e8a0008603365d29002db611559190da5bf99   # the protocol definitions it uses

OUT="$(cd "${1:-$(dirname "$0")}" && pwd)"
[[ "$(uname -m)" == aarch64 ]] || { echo "this builds the VM's (arm64) copy; run it on arm64 Linux" >&2; exit 1; }
command -v cargo >/dev/null && command -v git >/dev/null || { echo "needs cargo and git (sudo dnf install -y rust cargo git)" >&2; exit 1; }
W="$(mktemp -d /tmp/comet-build.XXXXXX)"
trap 'rm -rf "$W"' EXIT
export CARGO_HOME="$W/cargo" CARGO_TARGET_DIR="$W/target"

git clone -q --depth 1 --branch "$TAG" --recurse-submodules --shallow-submodules "$REPO" "$W/src"
[[ "$(git -C "$W/src" rev-parse HEAD)" == "$COMMIT" ]] || { echo "tag $TAG isn't commit $COMMIT any more; not building" >&2; exit 1; }
[[ "$(git -C "$W/src/proto" rev-parse HEAD)" == "$PROTO_COMMIT" ]] || { echo "the protocol submodule isn't $PROTO_COMMIT; not building" >&2; exit 1; }
cargo build --release --locked --manifest-path "$W/src/Cargo.toml"

install -m 0755 "$W/target/release/comet" "$OUT/comet-aarch64"
cp "$W/src/LICENSE" "$OUT/LICENSE-comet"
cp "$W/src/proto/LICENSE" "$OUT/LICENSE-proto-cc0"
SHA="$(sha256sum "$OUT/comet-aarch64" | cut -d' ' -f1)"
printf 'comet-aarch64 %s\n' "$SHA" > "$OUT/MANIFEST"
cat > "$OUT/BUILT" <<EOT
Comet $TAG (https://github.com/imLinguin/comet), Apache-2.0
commit  $COMMIT
proto   $PROTO_COMMIT (submodule Yepoleb/gog_protocols, CC0-1.0)
built   $(date -u +'%b %-d %Y') in Portalistic's own VM ($(. /etc/os-release; echo "$PRETTY_NAME") $(uname -m)), $(rustc --version | cut -d' ' -f1-2) / $(cargo --version | cut -d' ' -f1-2),
        cargo build --release --locked, nothing changed in the source
sha256  $SHA
EOT

# what is compiled in, and the licenses of it (for LICENSES.md and the app's notices)
(cd "$W/src" && cargo metadata --format-version 1 --locked --filter-platform aarch64-unknown-linux-gnu) > "$W/meta.json"
python3 - "$W/meta.json" "$CARGO_HOME/registry/src" "$OUT" <<'PY'
import glob, hashlib, json, os, re, sys
meta, reg, out = sys.argv[1:4]
m = json.load(open(meta))
res = {n["id"]: n for n in m["resolve"]["nodes"]}
seen, stack = set(), [m["resolve"]["root"]]
while stack:
    i = stack.pop()
    if i in seen:
        continue
    seen.add(i)
    for d in res[i]["deps"]:
        if any(k.get("kind") in (None, "normal") for k in d["dep_kinds"]):
            stack.append(d["pkg"])
pk = {p["id"]: p for p in m["packages"]}
rows = sorted((pk[i]["name"], pk[i]["version"], pk[i].get("license") or "?") for i in seen)
open(os.path.join(out, "CRATES.tsv"), "w").write("\n".join("\t".join(r) for r in rows) + "\n")
pat = re.compile(r"^(LICEN[CS]E|COPYING|NOTICE|UNLICENSE|COPYRIGHT)", re.I)
text, nofile, same = [], [], {}
for name, ver, lic in rows:
    if name == "comet":
        continue
    d = next((p for p in (os.path.join(r, f"{name}-{ver}") for r in glob.glob(reg + "/*")) if os.path.isdir(p)), None)
    files = sorted(f for f in os.listdir(d) if pat.match(f) and os.path.isfile(os.path.join(d, f))) if d else []
    if not files:
        nofile.append(f"  {name} {ver} -- {lic}")
        continue
    text.append(f"\n==== {name} {ver} -- {lic}\n")
    for f in files:
        t = open(os.path.join(d, f), errors="replace").read().strip()
        h = hashlib.sha256(t.encode()).hexdigest()
        if h in same and len(t) > 600:
            text.append(f"--- {f}: same text as in {same[h]}\n")
        else:
            same[h] = f"{name} {ver}"
            text.append(f"--- {f}\n{t}\n")
hdr = ("Third-party licenses of the packages compiled into the Comet build (guest/comet/comet-aarch64).\n"
       "Comet itself: Apache-2.0 (LICENSE-comet). Its protocol definitions (proto/): CC0-1.0 (LICENSE-proto-cc0).\n"
       "Collected from the package sources cargo downloaded for the build; the list with versions is CRATES.tsv.\n")
if nofile:
    hdr += "\nPackages whose download holds no license file (the license Cargo.toml names is given):\n" + "\n".join(nofile) + "\n"
open(os.path.join(out, "THIRD-PARTY-LICENSES.txt"), "w").write(hdr + "".join(text))
print(f"{len(rows)} packages compiled in; {len(nofile)} without a license file in their download")
PY
echo "built $OUT/comet-aarch64 ($SHA)"
