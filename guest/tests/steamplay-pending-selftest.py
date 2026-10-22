#!/usr/bin/env python3
"""bottle-steamplay pending: which games a running Steam would still run as their Linux version.
Runs on a fake HOME and Steam folder (no Steam needed); a stand-in process plays "Steam running".
  python3 steamplay-pending-selftest.py [path/to/bottle-steamplay]"""
import json, os, subprocess, sys, tempfile, time
from pathlib import Path

TOOLPATH = sys.argv[1] if len(sys.argv) > 1 else str(Path(__file__).resolve().parent.parent / "bottle-steamplay")
fails = []


def check(name, cond, extra=""):
    print(("ok   " if cond else "FAIL ") + name + (f"  [{extra}]" if extra and not cond else ""))
    if not cond:
        fails.append(name)


def acf(appid, name, installdir, windows):
    cfg = '\t"UserConfig"\n\t{\n\t\t"platform_override_dest"\t\t"linux"\n\t\t"platform_override_source"\t\t"windows"\n\t}\n' if windows else ""
    return ('"AppState"\n{\n\t"appid"\t\t"%s"\n\t"name"\t\t"%s"\n\t"installdir"\t\t"%s"\n%s}\n' % (appid, name, installdir, cfg))


def config(entries):
    body = "".join('\t\t\t\t\t"%s"\n\t\t\t\t\t{\n\t\t\t\t\t\t"name"\t\t"%s"\n\t\t\t\t\t\t"config"\t\t""\n\t\t\t\t\t\t"priority"\t\t"250"\n\t\t\t\t\t}\n' % (a, t) for a, t in entries)
    return ('"InstallConfigStore"\n{\n\t"Software"\n\t{\n\t\t"Valve"\n\t\t{\n\t\t\t"Steam"\n\t\t\t{\n\t\t\t\t"CompatToolMapping"\n\t\t\t\t{\n%s\t\t\t\t}\n\t\t\t}\n\t\t}\n\t}\n}\n' % body)


with tempfile.TemporaryDirectory() as tmp:
    tmp = Path(tmp)
    home, steam = tmp / "home", tmp / "Steam"
    apps = steam / "steamapps"
    (apps / "common").mkdir(parents=True)
    (steam / "config").mkdir(parents=True)
    (home / ".config/steamos-bottle").mkdir(parents=True)

    games = {   # appid: (name, windows install?)  (manifests don't say which build is installed: only Steam's cache knows)
        "588650": ("Dead Cells", False),        # has a Linux version: the one to list
        "570": ("Windows only", False),          # Steam's cache says windows only: Steam Play is its default, nothing to do
        "80": ("Not in the cache", False),       # not in Steam's cache: can't tell, listed
        "90": ("No system list", False),         # in the cache with no oslist: taken as Windows only
        "10": ("Already mapped", False),         # mapped to Proton: fine
        "20": ("Kept native", False),            # in native-apps
        "30": ("Player chose other", False),     # mapped to another tool by the player
        "40": ("Player chose Linux", False),     # steamplay-choices.json
        "50": ("Changed in Steam", False),       # steamplay-set.json says Proton, config says nothing now
    }
    for appid, (name, win) in games.items():
        (apps / f"appmanifest_{appid}.acf").write_text(acf(appid, name, name.replace(" ", ""), win))
    # a Steam Play tool (never a game)
    (apps / "appmanifest_1493710.acf").write_text(acf("1493710", "Proton Experimental", "Proton - Experimental", False))
    (apps / "common/Proton - Experimental").mkdir()
    (apps / "common/Proton - Experimental/toolmanifest.vdf").write_text('"manifest"\n{\n}\n')
    (steam / "config/config.vdf").write_text(config([("10", "proton_experimental"), ("30", "proton_9-0")]))
    cfgdir = home / ".config/steamos-bottle"
    (cfgdir / "native-apps").write_text("20  # kept\n")
    (cfgdir / "steamplay-choices.json").write_text(json.dumps({"40": ""}))
    (cfgdir / "steamplay-set.json").write_text(json.dumps({"10": "proton_experimental", "50": "proton_experimental"}))

    # Steam's own cache of app information (appcache/appinfo.vdf, binary, version 41): a string table at the end
    import struct
    strings = ["appinfo", "common", "name", "oslist", "type"]
    ix = {k: strings.index(k) for k in strings}

    def kv_obj(key, children):
        return b"\x00" + struct.pack("<I", ix[key]) + children + b"\x08"

    def kv_str(key, val):
        return b"\x01" + struct.pack("<I", ix[key]) + val.encode() + b"\0"

    def entry(appid, name, oslist):
        common = kv_str("name", name) + (kv_str("oslist", oslist) if oslist is not None else b"") + kv_str("type", "Game")
        body = b"\0" * 60 + kv_obj("appinfo", kv_obj("common", common)) + b"\x08"
        return struct.pack("<II", appid, len(body)) + body

    def write_appinfo(entries):
        blob = b"".join(entry(*e) for e in entries) + struct.pack("<I", 0)
        table = struct.pack("<I", len(strings)) + b"".join(s.encode() + b"\0" for s in strings)
        head = struct.pack("<IIq", 0x07564429, 1, 16 + len(blob))
        (steam / "appcache").mkdir(exist_ok=True)
        (steam / "appcache/appinfo.vdf").write_bytes(head + blob + table)

    write_appinfo([(60, "Another Game", "windows,linux"), (570, "Windows only", "windows"), (90, "No system list", None),
                   (588650, "Dead Cells", "windows,macos,linux"), (999, "Unrelated", "windows")])

    marker = "fakesteam-%d" % os.getpid()
    stand_in = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(120)", marker])
    base = dict(os.environ, HOME=str(home), BOTTLE_STEAM_DIR=str(steam))
    base.pop("BOTTLE_STEAMPLAY_TOOL", None)

    def run(*args, running=True):
        env = dict(base, BOTTLE_STEAM_PROC=("[f]akesteam-%d" % os.getpid()) if running else "[n]osuchprocess-xyz")
        r = subprocess.run([sys.executable, "-I", TOOLPATH, "pending", *args], env=env, capture_output=True, text=True)
        return r.returncode, [l for l in r.stdout.splitlines() if l], r.stderr

    try:
        time.sleep(0.3)
        rc, out, err = run(running=False)
        check("Steam not running: nothing listed", rc == 0 and out == [], f"{out} {err}")
        check("Steam not running: no notes written", not (cfgdir / "playmap-seen").exists())

        rc, out, err = run()
        check("first sighting: not listed yet (15 s rule)", rc == 0 and out == [], f"{out} {err}")
        seen = json.loads((cfgdir / "playmap-seen").read_text())
        check("first sighting noted for the games that may need the restart", set(seen) == {"588650", "80", "50"} or set(seen) == {"588650", "80"}, str(seen))

        # age the sighting
        for k in seen:
            seen[k] -= 60
        (cfgdir / "playmap-seen").write_text(json.dumps(seen))
        rc, out, err = run()
        ids = [l.split("\t")[1] for l in out]
        check("second sighting: Dead Cells listed with its name", "pending\t588650\tDead Cells" in out, str(out))
        check("a game for Windows only (Steam's cache) not listed", "570" not in ids)
        check("a game in the cache with no system list: taken as Windows only, not listed", "90" not in ids)
        check("a game missing from Steam's cache is listed (can't tell)", "pending\t80\tNot in the cache" in out, str(out))
        check("game mapped to Proton not listed", "10" not in ids)
        check("native-apps game not listed", "20" not in ids)
        check("player's other tool not listed", "30" not in ids)
        check("player's own choice (choices.json) not listed", "40" not in ids)
        check("Proton Experimental (a tool) not listed", "1493710" not in ids)
        check("listing without --mark leaves no 'tried' note", not (cfgdir / "playmap-tried").exists())

        rc, out2, err = run("--mark")
        check("--mark lists the same", out2 == out, str(out2))
        tried = json.loads((cfgdir / "playmap-tried").read_text())
        check("--mark notes the games as tried", "588650" in tried and "80" in tried and time.time() - tried["588650"] < 30, str(tried))
        rc, out3, err = run("--mark")
        check("tried game not listed again within 30 min", rc == 0 and out3 == [], str(out3))

        tried["588650"] -= 1900
        (cfgdir / "playmap-tried").write_text(json.dumps(tried))
        run()     # (the sighting note was dropped while it was "tried": 15 s rule again)
        s4 = json.loads((cfgdir / "playmap-seen").read_text())
        s4 = {k: v - 60 for k, v in s4.items()}
        (cfgdir / "playmap-seen").write_text(json.dumps(s4))
        rc, out4, err = run()
        check("listed again after 30 min", "pending\t588650\tDead Cells" in out4, str(out4))

        # after the restart: the mapping now has it -> gone, and the sighting note is cleaned up
        (steam / "config/config.vdf").write_text(config([("10", "proton_experimental"), ("30", "proton_9-0"), ("588650", "proton_experimental")]))
        rc, out5, err = run()
        ids5 = [l.split("\t")[1] for l in out5]
        check("mapped game no longer listed", "588650" not in ids5, str(out5))
        seen5 = json.loads((cfgdir / "playmap-seen").read_text())
        check("mapped game's sighting note removed", "588650" not in seen5, str(seen5))

        # a second new Linux game shows up
        (apps / "appmanifest_60.acf").write_text(acf("60", "Another Game", "AnotherGame", False))
        run()
        s6 = json.loads((cfgdir / "playmap-seen").read_text())
        s6["60"] -= 60
        (cfgdir / "playmap-seen").write_text(json.dumps(s6))
        rc, out6, err = run("--mark")
        check("a second new game is listed alone", [l.split("\t")[1] for l in out6] == ["60"], str(out6))

        # a cache that can't be read (damaged, or another version): nothing can be told, every candidate is listed
        (steam / "appcache/appinfo.vdf").write_bytes(b"\x28\x44\x56\x07garbage")
        (apps / "appmanifest_95.acf").write_text(acf("95", "Cache Gone", "CacheGone", False))
        run()
        s8 = json.loads((cfgdir / "playmap-seen").read_text())
        s8 = {k: v - 60 for k, v in s8.items()}
        (cfgdir / "playmap-seen").write_text(json.dumps(s8))
        rc, out8, err = run()
        check("unreadable cache: no crash, the candidates are listed", rc == 0 and "pending\t95\tCache Gone" in out8, f"{out8} {err}")
        (steam / "appcache/appinfo.vdf").write_bytes(b"")
        rc, out9, err = run()
        check("empty cache file: no crash", rc == 0, err)
        # no config.vdf at all (Steam never ran): a Linux install is listed too, nothing crashes
        (steam / "config/config.vdf").unlink()
        rc, out7, err = run()
        check("no config.vdf: no crash", rc == 0, err)
    finally:
        stand_in.kill()

print("\n%s" % ("ALL OK" if not fails else "FAILED: " + ", ".join(fails)))
sys.exit(1 if fails else 0)
