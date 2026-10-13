# Remove Steam Play settings (CompatToolMapping entries) for Steam's own tools (FEX, its
# runtime) from config.vdf, whatever tool they name. Steam must not be running.
import pathlib, re, shutil, sys
TOOLS = {"3127680", "4183110", "1826330", "1161040"}   # FEX, its runtime, EAC / BattlEye runtimes
p = pathlib.Path.home() / ".local/share/Steam/config/config.vdf"
t = p.read_text(errors="replace")
m = re.search(r'"CompatToolMapping"\s*\{', t)
if not m:
    print("Steam Play settings: none at all"); sys.exit(0)
start = m.end(); depth, i = 1, start
while i < len(t) and depth:
    if t[i] == '"':                      # skip strings (braces inside them don't count)
        i += 1
        while i < len(t) and t[i] != '"':
            i += 2 if t[i] == "\\" else 1
    elif t[i] == "{": depth += 1
    elif t[i] == "}": depth -= 1
    i += 1
body = t[start:i - 1]
found = re.findall(r'"(\d+)"\s*\{([^{}]*)\}', body)
print("Steam Play settings: " + (", ".join(f"{a}={re.search(r'\"name\"\s*\"([^\"]*)\"', b).group(1) if re.search(r'\"name\"', b) else '?'}" for a, b in found) or "none"))
new_body, n = re.subn(r'\s*"(' + "|".join(TOOLS) + r')"\s*\{[^{}]*\}', "", body)
if n:
    shutil.copy2(p, str(p) + ".bottle-fexfix")
    p.write_text(t[:start] + new_body + t[i - 1:])
print(f"Removed {n} Steam Play setting(s) for Steam's own tools (FEX, runtimes)")
for lc in (pathlib.Path.home() / ".local/share/Steam/userdata").glob("*/config/localconfig.vdf"):
    s = lc.read_text(errors="replace")
    for mm in re.finditer(r'"3127680"', s):
        print(f"(note) {lc.relative_to(pathlib.Path.home())} mentions 3127680: ...{s[mm.start():mm.start()+160]!r}")
