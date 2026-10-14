#!/usr/bin/env python3
"""Self-test for bottle-stores (GOG and Epic), with a pretend GOG, a pretend gogdl and a pretend Legendary:
no network, no Steam, no root. Run:  python3 guest/tests/stores-selftest.py   (prints "ALL PASSED" or what failed)"""
import json
import os
import struct
import subprocess
import sys
import tempfile
import textwrap
import threading
import time
import zlib
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
TOOL = HERE.parent / "bottle-stores"
failures = []


def check(cond, what):
    print(("ok    " if cond else "FAIL  ") + what)
    if not cond:
        failures.append(what)


# ---- a pretend GOG
GAMES = [
    {"id": 1207658930, "title": "Alpha Quest", "slug": "alpha_quest", "image": "//images-1.gog.com/aaa",
     "isGame": True, "worksOn": {"Windows": True, "Mac": False, "Linux": False},
     "releaseDate": {"date": "1999-06-01 00:00:00.000000", "timezone_type": 1, "timezone": "+02:00"}},
    {"id": 1207658931, "title": "beta Racer", "slug": "beta_racer", "image": "//images-1.gog.com/bbb",
     "isGame": True, "worksOn": {"Windows": True, "Mac": True, "Linux": False}, "releaseDate": None},
    {"id": 1207658932, "title": "Linux Only", "slug": "linux_only", "image": "", "isGame": True,
     "worksOn": {"Windows": False, "Mac": False, "Linux": True}},
]
PORT = 0
REV = [b""]            # appended to every picture the pretend GOG serves: change it and "GOG's art changed"
NOV2 = set()           # games whose v2 answer is missing (only the older /products answer exists)
GQL_ASKED = []         # the namespaces the pretend Epic store was asked about
EPIC_OFFERS = {        # what the pretend Epic store knows (by namespace): a base game with two editions and a DLC
    "ns-alphaquest": [
        {"id": "o1", "releaseDate": "2020-09-23T15:00:00.000Z", "pcReleaseDate": "2015-07-07T15:00:00.000Z", "items": [{"id": "item-alphaquest"}]},
        {"id": "o2", "releaseDate": "2012-01-01T00:00:00.000Z", "pcReleaseDate": None, "items": [{"id": "item-alphaquest"}]},
        {"id": "o3", "releaseDate": "2010-01-01T00:00:00.000Z", "pcReleaseDate": "2010-01-01T00:00:00.000Z", "items": [{"id": "dlc-item"}]}],
    "ns-zetabattle": [
        {"id": "o4", "releaseDate": "2021-05-05T00:00:00.000Z", "pcReleaseDate": None, "items": [{"id": "item-zetabattle"}]}],
}


class Fake(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, code, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
        if self.path == "/graphql":
            ns = (body.get("variables") or {}).get("ns")
            GQL_ASKED.append(ns)
            return self.reply(200, {"data": {"Catalog": {"catalogOffers": {"elements": EPIC_OFFERS.get(ns, [])}}}})
        self.reply(404, {})

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/userData.json":
            if self.headers.get("Authorization") != "Bearer tok-1":
                return self.reply(401, {})
            return self.reply(200, {"username": "tester", "email": "t@example.com"})
        if path == "/account/getFilteredProducts":
            if self.headers.get("Authorization") != "Bearer tok-1":
                return self.reply(401, {})
            page = int(self.path.split("page=")[1].split("&")[0]) if "page=" in self.path else 1
            return self.reply(200, {"page": page, "totalPages": 2,
                                    "products": GAMES[:2] if page == 1 else GAMES[2:]})
        if path.startswith("/products/"):
            gid = path.rsplit("/", 1)[1]
            return self.reply(200, {"title": "x", "images": {
                "background": f"http://127.0.0.1:{PORT}/img/{gid}.jpg",
                "icon": f"http://127.0.0.1:{PORT}/img/{gid}.png"}})
        if path.startswith("/v2/games/"):
            gid = path.rsplit("/", 1)[1]
            if gid in NOV2:
                return self.reply(404, {})
            b = f"http://127.0.0.1:{PORT}/img/{gid}"
            return self.reply(200, {"_links": {
                "self": {"href": b}, "store": {"href": "https://www.gog.com/en/game/x"},
                "boxArtImage": {"href": b + "_cover.jpg"}, "backgroundImage": {"href": b + "_bg.jpg"},
                "galaxyBackgroundImage": {"href": b + "_galaxy.jpg"}, "logo": {"href": b + "_logo.png"},
                "icon": {"href": b + ".png"}, "isRequiredByGames": [{"href": "https://api.gog.com/v2/games/1"}]}})
        if path.startswith("/img/"):
            name = path.rsplit("/", 1)[1]
            body = (b"\xff\xd8" if name.endswith("jpg") else b"\x89PNG") + name.encode() + REV[0]
            return self.reply(200, body, "image/jpeg")
        self.reply(404, {})


FAKE_GOGDL = r'''#!/usr/bin/env python3
import json, os, sys, time
argv = sys.argv[1:]
auth = None
if argv and argv[0] == "--auth-config-path":
    auth, argv = argv[1], argv[2:]
cmd = argv[0]
def arg(name, default=None):
    return argv[argv.index(name) + 1] if name in argv else default
if cmd == "auth":
    if "--code" in argv:
        code = arg("--code")
        if code != "GOODCODE12345678":
            print(json.dumps({"error": True})); sys.exit(0)
        data = {"access_token": "tok-1", "refresh_token": "ref", "expires_in": 3600, "loginTime": time.time()}
        open(auth, "w").write(json.dumps({"46899977096215655": data}))
        print(json.dumps(data))
    else:
        try:
            creds = json.load(open(auth))["46899977096215655"]
            print(json.dumps(creds))
        except Exception:
            print("null")
elif cmd == "info":
    gid = argv[1]
    if gid == "999":
        sys.stderr.write("[MAIN] ERROR: Game doesn't support content system api\n"); sys.exit(1)
    print(json.dumps({"size": {"download_size": 1000, "disk_size": int(os.environ.get("FAKE_DISK", "5000"))},
                      "dlcs": [], "buildId": "1", "languages": ["de-DE", "en-US"],
                      "folder_name": "Alpha Quest" if gid.endswith("930") else "Beta Racer",
                      "dependencies": [], "versionName": "1.0", "available_branches": [None], "builds": {}}))
elif cmd == "download":
    gid, path = argv[1], arg("--path")
    folder = "Alpha Quest" if gid.endswith("930") else "Beta Racer"
    d = os.path.join(path, folder)
    os.makedirs(os.path.join(d, "Bin"), exist_ok=True)
    open(os.path.join(d, "Bin", "Game.EXE"), "wb").write(b"MZ" + b"\0" * 100)
    open(os.path.join(d, f"goggame-{gid}.info"), "w").write(json.dumps({
        "gameId": gid, "name": folder, "playTasks": [
            {"category": "document", "type": "FileTask", "path": "manual.pdf", "name": "Manual"},
            {"category": "game", "isPrimary": True, "type": "FileTask", "path": "bin\\game.exe",
             "workingDir": "bin", "arguments": "-windowed", "name": folder},
            {"category": "launcher", "type": "URLTask", "link": "http://x"}]}))
    for pct, w in ((25.0, 1250), (50.0, 2500), (100.0, 5000)):
        sys.stderr.write(f"[PROGRESS] INFO: = Progress: {pct:.02f} {w}/5000, Running for: 00:00:01, ETA: 00:00:0{int(100 - pct) // 40}\n")
        sys.stderr.write("[PROGRESS] INFO: = Downloaded: 1.00 MiB, Written: 1.00 MiB\n")
        sys.stderr.flush()
    os.makedirs(os.path.join(os.environ["GOGDL_CONFIG_PATH"], "heroic_gogdl", "manifests"), exist_ok=True)
    open(os.path.join(os.environ["GOGDL_CONFIG_PATH"], "heroic_gogdl", "manifests", gid), "w").write("{}")
'''


FAKE_LEGENDARY = r'''#!/usr/bin/env python3
import json, os, sys
argv = sys.argv[1:]
if argv[:1] == ["-y"]:
    argv = argv[1:]
cfg, port = os.environ["LEGENDARY_CONFIG_PATH"], os.environ["FAKE_PORT"]
os.makedirs(cfg + "/metadata", exist_ok=True)
cmd = argv[0]
def arg(name):
    return argv[argv.index(name) + 1] if name in argv else None
def installed():
    try:
        return json.load(open(cfg + "/installed.json"))
    except Exception:
        return {}
def imgs(n):
    return [{"type": t, "url": f"http://127.0.0.1:{port}/img/epic_{n}_{t}.{e}"}
            for t, e in (("DieselGameBoxTall", "jpg"), ("DieselGameBox", "jpg"), ("DieselGameBoxLogo", "png"), ("Thumbnail", "png"))]
VER = os.environ.get("FAKE_EPIC_VERSION", "1.0")
LIB = [("zetabattle", "Zeta Battle", "5", {}), ("alphaquest", "  Alpha Quest ", VER, {}),
       ("eagame", "An EA Game", "2", {"ThirdPartyManagedApp": {"type": "STRING", "value": "The EA app"}}),
       ("maconly", "Mac Only", None, {})]
FOLDERS = {"alphaquest": "AlphaQuest", "zetabattle": "ZetaBattle"}
if cmd == "auth":
    if arg("--code") != "EPICGOODCODE0123456789":
        sys.stderr.write("[cli] ERROR: Logging in failed with HTTPError, please try again.\n"); sys.exit(1)
    open(cfg + "/user.json", "w").write(json.dumps({
        "displayName": "EpicTester", "account_id": "acc123", "refresh_token": "ref-secret", "access_token": "acc-secret",
        "expires_at": "2099-01-01T00:00:00.000Z", "refresh_expires_at": "2099-01-01T00:00:00.000Z"}))
    sys.stderr.write('[cli] INFO: Successfully logged in as "EpicTester"\n')
elif cmd == "list":
    if not os.path.exists(cfg + "/user.json"):
        sys.stderr.write("[cli] ERROR: Login failed, cannot continue!\n"); sys.exit(1)
    sys.stderr.write("[cli] INFO: Getting game list... (this may take a while)\n")
    print(json.dumps([{"app_name": a, "app_title": t, "base_urls": [], "dlcs": [],
                       "asset_infos": {"Windows": {"build_version": v}} if v else {"Mac": {"build_version": "1"}},
                       "metadata": {"keyImages": imgs(a), "customAttributes": attrs, "namespace": "ns-" + a, "id": "item-" + a}}
                      for a, t, v, attrs in LIB]))
elif cmd == "install":
    app, base = argv[1], arg("--base-path")
    if os.environ.get("FAKE_EPIC_FAIL") == "space":
        print(" ! Failure: Not enough available disk space! 1.00 GiB < 50.00 GiB")
        sys.stderr.write("[cli] CRITICAL: Installation cannot proceed, exiting.\n"); sys.exit(1)
    if app not in FOLDERS:
        sys.stderr.write(f'[cli] ERROR: Could not find "{app}" in list of available games.\n'); sys.exit(1)
    d = os.path.join(base, FOLDERS[app])
    os.makedirs(d + "/Binaries/Win64", exist_ok=True)
    open(d + "/Binaries/Win64/Game.exe", "wb").write(b"MZ" + b"\0" * 100)
    for pct, c in ((25.0, 10), (50.0, 20), (100.0, 40)):
        sys.stderr.write(f"[DLManager] INFO: = Progress: {pct:.02f}% ({c}/40), Running for 00:00:01, ETA: 00:00:03\n")
        sys.stderr.write("[DLManager] INFO:  - Downloaded: 1.00 MiB, Written: 1.00 MiB\n")
        sys.stderr.write("[DLManager] INFO:  - Cache usage: 1.00 MiB, active tasks: 4\n")
        sys.stderr.write("[DLManager] INFO:  + Download\t- 1.00 MiB/s (raw) / 1.00 MiB/s (decompressed)\n")
        sys.stderr.write("[DLManager] INFO:  + Disk\t- 1.00 MiB/s (write) / 0.00 MiB/s (read)\n")
        sys.stderr.flush()
    inst = installed()
    inst[app] = {"app_name": app, "title": "Alpha Quest" if app == "alphaquest" else "Zeta Battle", "version": VER,
                 "install_path": d, "executable": "Binaries\\win64\\game.EXE", "install_size": 4242, "platform": "Windows"}
    json.dump(inst, open(cfg + "/installed.json", "w"))
    json.dump({"app_name": app, "app_title": app, "metadata": {"keyImages": imgs(app)}}, open(f"{cfg}/metadata/{app}.json", "w"))
elif cmd == "launch":
    app, mode, offline = argv[1], os.environ.get("FAKE_EPIC_LAUNCH", "ok"), "--offline" in argv
    if app not in installed() or mode == "fail" or (mode == "offline-only" and not offline):
        sys.stderr.write("[cli] ERROR: Login failed, cannot continue!\n"); sys.exit(1)
    print(json.dumps({"game_parameters": ["-fromManifest"], "user_parameters": [], "launch_command": [], "environment": {},
                      "egl_parameters": ["-AUTH_LOGIN=unused", "-AUTH_PASSWORD=" + ("" if offline else "TOKEN123"),
                                         "-AUTH_TYPE=exchangecode", "-epicapp=" + app]}))
elif cmd == "uninstall":
    inst = installed()
    inst.pop(argv[-1], None)
    json.dump(inst, open(cfg + "/installed.json", "w"))
'''


def run(*args, env=None, check_code=None):
    e = dict(os.environ)
    e.update(ENV)
    if env:
        e.update(env)
    r = subprocess.run([sys.executable, str(TOOL), *args], capture_output=True, text=True, env=e)
    if check_code is not None:
        check(r.returncode == check_code, f"exit {check_code}: bottle-stores {' '.join(args)}  [{r.stdout.strip()[-120:]}{r.stderr.strip()[-120:]}]")
    return r


def bvdf(entries):
    """A shortcuts.vdf as Steam writes it."""
    out = b"\x00shortcuts\x00"
    for i, e in enumerate(entries):
        out += b"\x00" + str(i).encode() + b"\x00"
        for k, v in e.items():
            if isinstance(v, int):
                out += b"\x02" + k.encode() + b"\x00" + struct.pack("<I", v & 0xFFFFFFFF)
            elif isinstance(v, list):
                out += b"\x00" + k.encode() + b"\x00"
                for j, t in enumerate(v):
                    out += b"\x01" + str(j).encode() + b"\x00" + t.encode() + b"\x00"
                out += b"\x08"
            else:
                out += b"\x01" + k.encode() + b"\x00" + v.encode() + b"\x00"
        out += b"\x08"
    return out + b"\x08\x08"


def main():
    global PORT, ENV
    srv = HTTPServer(("127.0.0.1", 0), Fake)
    PORT = srv.server_address[1]
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    tmp = Path(tempfile.mkdtemp(prefix="stores-test-"))
    (tmp / "gogdl").write_text(FAKE_GOGDL)
    os.chmod(tmp / "gogdl", 0o755)
    (tmp / "legendary").write_text(FAKE_LEGENDARY)
    os.chmod(tmp / "legendary", 0o755)
    steam, mounts = tmp / "Steam", tmp / "mnt"
    (mounts / "mac").mkdir(parents=True)
    (steam / "userdata/12345/config").mkdir(parents=True)
    (steam / "userdata/0").mkdir(parents=True)
    (tmp / "libraries.json").write_text(json.dumps(
        {"default": "mac", "stamp": "1", "folders": [
            {"name": "mac", "label": "Mac", "path": "/Users/me/Games/Portalistic"},
            {"name": "ext", "label": "Drive", "path": "/Volumes/X/Portalistic Library"}]}))
    ENV = {"HOME": str(tmp / "home"), "BOTTLE_STORES_DIR": str(tmp / "state"), "BOTTLE_STEAM_DIR": str(steam),
           "BOTTLE_LIBRARIES_CONF": str(tmp / "libraries.json"), "BOTTLE_LIBRARY_ROOT": str(mounts),
           "BOTTLE_GOGDL": f"{sys.executable} {tmp / 'gogdl'}", "BOTTLE_GOG_EMBED": f"http://127.0.0.1:{PORT}",
           "BOTTLE_GOG_API": f"http://127.0.0.1:{PORT}", "BOTTLE_EPIC_GRAPHQL": f"http://127.0.0.1:{PORT}/graphql",
           "BOTTLE_LEGENDARY": f"{sys.executable} {tmp / 'legendary'}", "FAKE_PORT": str(PORT),
           "BOTTLE_STEAM_PROC": "[s]tores-test-no-steam( |$)"}   # (a real Steam running here must not count)
    (tmp / "home").mkdir()

    r = run("gog", "status", "--json", check_code=0)
    st = json.loads(r.stdout)
    check(st["signedIn"] is False and st["installed"] == 0, "status before signing in")
    check(run("gog", "list", check_code=1).stdout.count("not signed in") == 1, "list needs a sign-in")
    check(run("gog", "login-url").stdout.startswith("https://auth.gog.com/auth?client_id="), "login-url")

    r = run("gog", "login", "https://embed.gog.com/on_login_success?origin=client&code=WRONGCODE1234567890")
    check(r.returncode == 1 and "didn't accept" in r.stdout and not (tmp / "state/gog-auth.json").exists(), "a wrong code is refused, nothing kept")
    check(run("gog", "login", "nonsense with spaces").returncode == 1, "text without a code is refused")
    r = run("gog", "login", "https://embed.gog.com/on_login_success?origin=client&code=GOODCODE12345678", check_code=0)
    check("Signed in to GOG as tester" in r.stdout, "login with the address")
    check("tok-1" not in r.stdout + r.stderr, "no token in the output")
    mode = (tmp / "state/gog-auth.json").stat().st_mode & 0o777
    check(mode == 0o600, f"auth file is private (mode {oct(mode)})")
    check(run("gog", "status", "--json").stdout.count('"signedIn": true') == 1, "status after signing in")

    r = run("gog", "list", "--json", "--refresh", check_code=0)
    rows = json.loads(r.stdout)["games"]
    check([g["title"] for g in rows] == ["Alpha Quest", "beta Racer"], f"list: Windows games only, by title ({[g['title'] for g in rows]})")
    check([g["year"] for g in rows] == [1999, 0], f"list: the release year from GOG, 0 when GOG gives none ({[g['year'] for g in rows]})")
    cache_file = tmp / "state/gog-library.json"
    old = json.loads(cache_file.read_text())
    check(old.get("v") == 2, "list: the cached list is marked with its version")
    for g in old["games"]:
        g.pop("year", None)
    old.pop("v", None)
    cache_file.write_text(json.dumps(old))
    rows = json.loads(run("gog", "list", "--json", check_code=0).stdout)["games"]
    check([g["year"] for g in rows] == [1999, 0], "list: a cached list from before the years is fetched again")

    r = run("gog", "folders", "--json", check_code=0)
    f = json.loads(r.stdout)["folders"]
    check([x["name"] for x in f] == ["mac", "vm"], f"folders: mounted ones + vm ({[x['name'] for x in f]})")
    check(f[0]["default"] and not f[1]["default"], "default folder")

    # install
    r = run("gog", "install", "1207658930", check_code=0)
    out = r.stdout
    check("@@progress 25.0 1250 5000" in out and "@@progress 100.0 5000 5000" in out, "progress lines for the app")
    check("@@done 1207658930" in out, "done line")
    dest = mounts / "mac/GOG Games/Alpha Quest"
    check((dest / "Bin/Game.EXE").is_file(), "game files in the default folder")
    games = json.loads((tmp / "state/games.json").read_text())["gog"]
    rec = games["1207658930"]
    check(rec["exe"] == str(dest / "Bin/Game.EXE"), f"exe found case-insensitively ({rec['exe']})")
    check(rec["args"] == "-windowed" and rec["startdir"] == str(dest / "Bin"), "arguments and working directory")
    exe_q = f'"{rec["exe"]}"'
    want = (zlib.crc32((exe_q + "Alpha Quest").encode()) & 0xFFFFFFFF) | 0x80000000
    check(int(rec["appid"]) == want and want >= 2 ** 31, "shortcut app ID is crc32(quoted exe + name) | 0x80000000")
    check((tmp / "state/art/1207658930_hero.jpg").is_file() and rec["icon"].endswith("_icon.png"), "artwork fetched")
    art = tmp / "state/art"
    check(all((art / f"1207658930_{k}").is_file() for k in ("cover.jpg", "hero.jpg", "logo.png", "icon.png")),
          "cover, background, logo and icon fetched")
    check((art / "1207658930_hero.jpg").read_bytes() == b"\xff\xd81207658930_galaxy.jpg", "the Galaxy background is the hero")
    check(rec.get("art") == 2 and rec.get("art_try"), "the pictures are noted as fetched")
    # not enough space
    r = run("gog", "install", "1207658931", env={"FAKE_DISK": str(10 ** 15)})
    check(r.returncode == 1 and "needs" in r.stdout and "free" in r.stdout, "refuses when the folder is too small")
    check(run("gog", "install", "999").returncode == 1, "a game without a Windows version fails cleanly")
    check(run("gog", "install", "1207658931", "--folder", "nope").returncode == 1, "unknown folder refused")
    check(run("gog", "install", "1207658931", "--folder", "vm", check_code=0).returncode == 0
          and (tmp / "home/Games/GOG Games/Beta Racer/Bin/Game.EXE").is_file(), "install to the VM's disk")

    # sync into Steam's shortcuts
    udir = steam / "userdata/12345/config"
    theirs = {"appid": 0x80001234, "AppName": "My Own Game", "Exe": '"/opt/own/game"', "StartDir": '"/opt/own/"',
              "icon": "", "ShortcutPath": "", "LaunchOptions": "", "IsHidden": 0, "tags": ["Mine"], "LastPlayTime": 77}
    (udir / "shortcuts.vdf").write_bytes(bvdf([theirs]))
    r = run("sync", check_code=0)
    check("2 added" in r.stdout, f"sync adds both games ({r.stdout.strip()})")
    data = (udir / "shortcuts.vdf").read_bytes()
    check(b"My Own Game" in data and b"Alpha Quest" in data and b"Beta Racer" in data, "their shortcut kept, ours added")
    check((udir / "shortcuts.vdf.bottle-backup").is_file(), "a backup of Steam's file")
    sys.path.insert(0, str(TOOL.parent))
    import importlib.machinery, importlib.util
    loader = importlib.machinery.SourceFileLoader("bottle_stores", str(TOOL))
    spec = importlib.util.spec_from_loader("bottle_stores", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    parsed = mod.bvdf_load(data)["shortcuts"]
    check(list(parsed) == ["0", "1", "2"], f"entries numbered in a row ({list(parsed)})")
    entry = next(e for e in parsed.values() if mod.sval(e, "AppName") == "Alpha Quest")
    check(mod.ival(entry, "appid") == want and mod.sval(entry, "Exe") == exe_q, "app ID and quoted Exe in the entry")
    check(mod.sval(entry, "ShortcutPath") == "portalistic:gog:1207658930" and mod.sval(entry, "LaunchOptions") == "-windowed", "marker and options")
    check(mod.bvdf_dump(mod.bvdf_load(bvdf([theirs]))) == bvdf([theirs]), "round trip of Steam's own format")
    check((udir / f"grid/{want}_hero.jpg").is_file(), "artwork copied to Steam's grid folder")
    grid = udir / "grid"
    for name in (f"{want}p.jpg", f"{want}_hero.jpg", f"{want}.jpg", f"{want}_logo.png"):
        check((grid / name).is_file(), f"{name} (tall tile, banner, wide tile, logo) is in the grid folder")
    again = run("sync", check_code=0)
    check(again.stdout.strip() == "", f"a second sync changes nothing ({again.stdout.strip()!r})")
    ids = run("ids", check_code=0).stdout.split()
    check(str(want) in ids and len(ids) == 2, f"ids: {ids}")

    # pictures: a player's own stay, a missing one comes back, ours follow GOG's when they change
    def alpha(**fields):
        gj = json.loads((tmp / "state/games.json").read_text())
        for k, v in fields.items():
            if v is None:
                gj["gog"]["1207658930"].pop(k, None)
            else:
                gj["gog"]["1207658930"][k] = v
        (tmp / "state/games.json").write_text(json.dumps(gj))
        return gj["gog"]["1207658930"]

    (grid / f"{want}_logo.png").write_bytes(b"\x89PNGmine")
    (grid / f"{want}p.jpg").unlink()
    run("sync", check_code=0)
    check((grid / f"{want}_logo.png").read_bytes() == b"\x89PNGmine", "a logo the player chose is kept")
    check((grid / f"{want}p.jpg").is_file(), "a missing picture is put back by a sync that changes nothing else")
    # a game from before the cover was fetched (no note) gets the new pictures; GOG's art has changed since
    alpha(art=None, art_try=None)
    REV[0] = b"-r2"
    run("sync", check_code=0)
    new_hero = b"\xff\xd81207658930_galaxy.jpg-r2"
    check((grid / f"{want}_hero.jpg").read_bytes() == new_hero and (grid / f"{want}.jpg").read_bytes() == new_hero,
          "our earlier banner and wide tile are replaced by GOG's new ones")
    check((grid / f"{want}p.jpg").read_bytes() == b"\xff\xd81207658930_cover.jpg-r2", "the cover too")
    check((grid / f"{want}_logo.png").read_bytes() == b"\x89PNGmine", "the player's logo is still kept")
    check((art / "1207658930_logo.png").read_bytes() == b"\x89PNG1207658930_logo.png-r2" and alpha()["art"] == 2,
          "our copy follows GOG's, and the game is noted as done")
    # GOG out of reach: noted, not marked done, and not asked again within the hour
    alpha(art=0, art_try=0)
    run("sync", env={"BOTTLE_GOG_API": "http://127.0.0.1:1"}, check_code=0)
    g = alpha()
    check(g["art"] == 0 and g["art_try"] > 0, "GOG out of reach: the try is noted, the game isn't marked done")
    REV[0] = b"-r3"
    tried = alpha(art=0, art_try=int(time.time()) - 100)["art_try"]
    run("sync", check_code=0)
    check(alpha()["art_try"] == tried and (grid / f"{want}.jpg").read_bytes() == new_hero, "no new try within the hour")
    # only the older GOG answer: its background and icon now, the cover and logo on a later try
    NOV2.add("1207658930")
    alpha(art=0, art_try=0)
    run("sync", check_code=0)
    check(alpha()["art"] == 0 and (art / "1207658930_hero.jpg").read_bytes() == b"\xff\xd81207658930.jpg-r3",
          "the older answer's background is used, the game stays marked as not done")
    NOV2.discard("1207658930")
    alpha(art_try=0)
    run("sync", check_code=0)
    check(alpha()["art"] == 2 and (art / "1207658930_hero.jpg").read_bytes() == b"\xff\xd81207658930_galaxy.jpg-r3",
          "the next try gets everything")

    # a game the player changed in Steam keeps their changes (last play time)
    parsed2 = mod.bvdf_load((udir / "shortcuts.vdf").read_bytes())
    for e in parsed2["shortcuts"].values():
        if mod.sval(e, "AppName") == "Alpha Quest":
            e["LastPlayTime"] = (2, 4242)
    (udir / "shortcuts.vdf").write_bytes(mod.bvdf_dump(parsed2))
    run("sync", check_code=0)
    e2 = next(e for e in mod.bvdf_load((udir / "shortcuts.vdf").read_bytes())["shortcuts"].values() if mod.sval(e, "AppName") == "Alpha Quest")
    check(mod.ival(e2, "LastPlayTime") == 4242, "Steam's own fields in our entry survive a sync")

    # games that use GOG's Galaxy SDK: launch options that start Comet beside them
    brdir = tmp / "home/Games/GOG Games/Beta Racer"
    check(mod.uses_galaxy(brdir) is False, "no Galaxy SDK in a plain game")
    check(mod.uses_galaxy(tmp / "no-such-folder") is None, "a folder that isn't there: unknown, not 'no'")
    deep = tmp / "deep" / "a" / "b" / "c" / "d" / "e"
    deep.mkdir(parents=True)
    (deep / "Galaxy64.dll").write_bytes(b"MZ")
    check(mod.uses_galaxy(tmp / "deep") is False, "a Galaxy dll five levels down isn't looked for")
    (brdir / "Bin").mkdir(exist_ok=True)
    (brdir / "Bin" / "GALAXY64.DLL").write_bytes(b"MZ")
    check(mod.uses_galaxy(brdir) is True, "Galaxy SDK found (any case, a level down)")
    check(mod.launch_options({"args": "-x", "galaxy": True}) == f"{mod.COMET_RUN} %command% -x", "launch options with Comet")
    check(mod.launch_options({"args": "", "galaxy": True}) == f"{mod.COMET_RUN} %command%", "launch options with Comet, no arguments")
    check(mod.launch_options({"args": "-x"}) == "-x" and mod.launch_options({"args": "", "galaxy": False}) == "", "plain launch options")
    gj = json.loads((tmp / "state/games.json").read_text())
    gj["gog"]["1207658931"].pop("galaxy", None)          # (a game installed before this was checked)
    (tmp / "state/games.json").write_text(json.dumps(gj))
    run("sync", check_code=0)
    e3 = next(e for e in mod.bvdf_load((udir / "shortcuts.vdf").read_bytes())["shortcuts"].values() if mod.sval(e, "AppName") == "beta Racer")
    check(mod.sval(e3, "LaunchOptions") == f"{mod.COMET_RUN} %command% -windowed", f"sync notices the Galaxy SDK ({mod.sval(e3, 'LaunchOptions')!r})")
    check(json.loads((tmp / "state/games.json").read_text())["gog"]["1207658931"].get("galaxy") is True, "and remembers it")
    e4 = next(e for e in mod.bvdf_load((udir / "shortcuts.vdf").read_bytes())["shortcuts"].values() if mod.sval(e, "AppName") == "Alpha Quest")
    check(mod.sval(e4, "LaunchOptions") == "-windowed", "a game without it keeps plain options")

    # `run`: a pretend Comet
    import socket as _socket
    sk = _socket.socket(); sk.bind(("127.0.0.1", 0)); cport = sk.getsockname()[1]; sk.close()
    cdir = tmp / "cometdir"; cdir.mkdir()
    out = tmp / "fakecomet"
    (cdir / "comet").write_text(textwrap.dedent(f'''\
        #!{sys.executable}
        import json, os, signal, socket, sys, time
        out = os.environ["FAKE_COMET_OUT"]
        auth = os.path.join(os.environ["XDG_CONFIG_PATH"], "heroic/gog_store/auth.json")
        open(out + ".started", "a").write(json.dumps({{"argv": sys.argv[1:], "ld": os.environ.get("LD_LIBRARY_PATH"),
            "link": os.path.islink(auth), "readable": os.path.isfile(auth)}}) + "\\n")
        s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind(("127.0.0.1", int(os.environ["BOTTLE_COMET_PORT"]))); s.listen(5)
        def stop(*a):
            open(out + ".stopped", "a").write("x\\n"); os._exit(0)
        signal.signal(signal.SIGINT, stop); signal.signal(signal.SIGTERM, stop)
        time.sleep(1.2)
        d = os.path.join(os.environ["XDG_DATA_HOME"], "comet/redist"); os.makedirs(d, exist_ok=True)
        open(os.path.join(d, ".desktop-galaxy-peer-windows.toml"), "w").write("x")
        while True: time.sleep(0.2)
        '''))
    os.chmod(cdir / "comet", 0o755)
    renv = {"BOTTLE_COMET_DIR": str(cdir), "BOTTLE_COMET_PORT": str(cport), "XDG_DATA_HOME": str(tmp / "xdg"),
            "FAKE_COMET_OUT": str(out), "LD_LIBRARY_PATH": "/nonexistent-lib-dir"}
    peer = tmp / "xdg/comet/redist/.desktop-galaxy-peer-windows.toml"
    game = ["bash", "-c", 'test -e "$1" && echo peer-ready || echo peer-missing; echo "ld=${LD_LIBRARY_PATH-unset}"; exit 7', "_", str(peer)]
    check(not mod.port_listening(cport), "port_listening: nothing there yet")
    r = run("run", "--", *game, env=renv)
    check(r.returncode == 7, f"run passes the game's exit code on ({r.returncode}; {r.stdout.strip()[-100:]} {r.stderr.strip()[-100:]})")
    check("peer-ready" in r.stdout, "the game starts only after Comet has its Galaxy files")
    check("ld=/nonexistent-lib-dir" in r.stdout, "the game keeps its own library path")
    started = [json.loads(l) for l in Path(str(out) + ".started").read_text().splitlines()]
    check(len(started) == 1 and started[0]["argv"] == ["--from-heroic", "--username", "tester"], f"Comet started once, signed in as the account ({started})")
    check(started[0]["ld"] is None and started[0]["link"] and started[0]["readable"], "Comet gets no library overrides, and finds the sign-in through the private link")
    check("tok-1" not in " ".join(started[0]["argv"]), "no token on Comet's command line")
    check(Path(str(out) + ".stopped").is_file() and not mod.port_listening(cport), "Comet stopped when the game ended")
    check((tmp / "state/comet-cfg").stat().st_mode & 0o777 == 0o700, "the link's folder is private")
    # Comet already running (the player's, or another game's): left alone
    for f in (Path(str(out) + ".started"), Path(str(out) + ".stopped")):
        f.unlink()
    pre = subprocess.Popen([str(cdir / "comet")], env=dict(os.environ, XDG_CONFIG_PATH=str(tmp / "unused"), **renv))
    for _ in range(40):
        if mod.port_listening(cport):
            break
        time.sleep(0.1)
    r = run("run", "--", "bash", "-c", "exit 0", env=renv)
    pre.poll()
    check(r.returncode == 0 and pre.poll() is None and len(Path(str(out) + ".started").read_text().splitlines()) == 1,
          "a Comet that's already running is reused and left running")
    pre.send_signal(2); pre.wait(5)
    # no Comet installed: the game starts anyway
    r = run("run", "--", "bash", "-c", "echo hi; exit 3", env=dict(renv, BOTTLE_COMET_DIR=str(tmp / "nothing-here")))
    check(r.returncode == 3 and "hi" in r.stdout, "without Comet the game just runs")
    check("isn't installed" in (tmp / "home/.cache/steamos-bottle/comet.log").read_text(), "and the reason goes in Comet's log")
    r = run("run", "--", str(tmp / "nope-not-a-program"), env=renv)
    check(r.returncode == 127, "a command that doesn't exist: 127")
    # a stop signal reaches the game, and Comet still goes
    for f in (Path(str(out) + ".started"), Path(str(out) + ".stopped")):
        f.unlink(missing_ok=True)
    e = dict(os.environ); e.update(ENV); e.update(renv)
    p = subprocess.Popen([sys.executable, str(TOOL), "run", "--", "sleep", "30"], env=e)
    for _ in range(100):
        if mod.port_listening(cport) and peer.is_file():
            break
        time.sleep(0.1)
    time.sleep(0.6)                                     # (let it get past starting the game)
    p.send_signal(15)
    rc = p.wait(15)
    check(rc == 143, f"SIGTERM goes on to the game ({rc})")
    check(Path(str(out) + ".stopped").is_file() and not mod.port_listening(cport), "Comet stopped after the signal too")

    # Steam running: sync waits
    fake_steam = subprocess.Popen(["bash", "-c", "exec -a /x/stores-test-steam/steam sleep 30"])
    try:
        time.sleep(0.3)
        r = run("sync", env={"BOTTLE_STEAM_PROC": "[s]tores-test-steam/steam( |$)"})
        check(r.returncode == 1 and "Steam is running" in r.stdout, "sync refuses while Steam runs")
        check(run("sync", "--force", env={"BOTTLE_STEAM_PROC": "[s]tores-test-steam/steam( |$)"}).returncode == 0, "sync --force goes ahead")
    finally:
        fake_steam.kill()

    # remove
    r = run("gog", "remove", "1207658930", check_code=0)
    check(not dest.exists(), "files deleted")
    check(not (tmp / "state/gogdl/heroic_gogdl/manifests/1207658930").exists(), "gogdl's manifest forgotten")
    check("1207658930" not in json.loads((tmp / "state/games.json").read_text())["gog"], "record gone")
    run("sync", check_code=0)
    left = [mod.sval(e, "AppName") for e in mod.bvdf_load((udir / "shortcuts.vdf").read_bytes())["shortcuts"].values()]
    check(left == ["My Own Game", "beta Racer"], f"shortcut taken out, others stay ({left})")
    check(not any((udir / f"grid/{want}{suffix}").exists() for suffix in ("_hero.jpg", ".jpg", "p.jpg", "_logo.png")),
          "artwork taken out")
    check(not list((tmp / "state/art").glob("1207658930_*")), "our copies of the pictures taken out")
    check(run("gog", "remove", "1207658930").returncode == 1, "removing twice says so")
    # a record whose folder isn't a GOG Games folder: files kept
    games = json.loads((tmp / "state/games.json").read_text())
    other = tmp / "precious"
    other.mkdir()
    (other / "keep.txt").write_text("x")
    games["gog"]["1207658931"]["dir"] = str(other)
    (tmp / "state/games.json").write_text(json.dumps(games))
    run("gog", "remove", "1207658931", check_code=0)
    check((other / "keep.txt").exists(), "never deletes outside a GOG Games folder")

    # Steam Play and DXVK know the games: the same state under the real place (HOME/.config/steamos-bottle/stores)
    real = tmp / "home/.config/steamos-bottle/stores"
    real.mkdir(parents=True)
    (real / "games.json").write_text(json.dumps({"gog": {"7": {"title": "Seven", "appid": "2500000001", "dir": str(tmp / "seven")}}}))
    (tmp / "seven").mkdir()
    (steam / "steamapps").mkdir(exist_ok=True)
    (steam / "config").mkdir(exist_ok=True)
    (steam / "config/config.vdf").write_text('"InstallConfigStore"\n{\n\t"Software"\n\t{\n\t\t"Valve"\n\t\t{\n\t\t\t"Steam"\n\t\t\t{\n\t\t\t}\n\t\t}\n\t}\n}\n')
    play = HERE.parent / "bottle-steamplay"
    e = dict(os.environ, HOME=str(tmp / "home"), BOTTLE_STEAM_DIR=str(steam), BOTTLE_STEAM_PROC=ENV["BOTTLE_STEAM_PROC"])
    r = subprocess.run([sys.executable, str(play), "map"], capture_output=True, text=True, env=e)
    cfg = (steam / "config/config.vdf").read_text()
    check(r.returncode == 0 and '"2500000001"' in cfg and "proton_experimental" in cfg, f"Steam Play: a store game is set to Proton ({r.stdout.strip()[:100]})")
    subprocess.run([sys.executable, str(play), "map"], capture_output=True, text=True, env=e)
    check(cfg == (steam / "config/config.vdf").read_text(), "Steam Play: a second map changes nothing")
    (real / "games.json").write_text("{}")
    subprocess.run([sys.executable, str(play), "map"], capture_output=True, text=True, env=e)
    check('"2500000001"' not in (steam / "config/config.vdf").read_text(), "Steam Play: the entry goes when the game does")
    (real / "games.json").write_text(json.dumps({"gog": {"7": {"title": "Seven", "appid": "2500000001", "dir": str(tmp / "seven"), "installed": 5}}}))
    loader2 = importlib.machinery.SourceFileLoader("bottle_dxvk", str(HERE.parent / "bottle-dxvk"))
    spec2 = importlib.util.spec_from_loader("bottle_dxvk", loader2)
    dx = importlib.util.module_from_spec(spec2)
    os.environ["HOME"] = str(tmp / "home")
    dx.__dict__["__name__"] = "bottle_dxvk"
    loader2.exec_module(dx)
    sg = dx.store_games()
    check(len(sg) == 1 and sg[0]["appid"] == "2500000001" and sg[0]["path"] == tmp / "seven", f"DXVK sees the store game ({sg})")

    # ---- Epic Games, with a pretend Legendary
    epic_state = tmp / "state/legendary"
    r = run("epic", "status", "--json", check_code=0)
    check(json.loads(r.stdout)["signedIn"] is False and json.loads(r.stdout)["installed"] == 0, "epic: status before signing in")
    check("not signed in" in run("epic", "list", check_code=1).stdout, "epic: list needs a sign-in")
    url = run("epic", "login-url").stdout.strip()
    check(url.startswith("https://www.epicgames.com/id/login?redirectUrl=") and "34a02cf8f4414e29b15921876da36f9a" in url
          and "responseType%3Dcode" in url, "epic: login-url")
    r = run("epic", "login", '{"authorizationCode":"WRONGCODE0123456789","sid":null}')
    check(r.returncode == 1 and "didn't accept" in r.stdout and not (epic_state / "user.json").exists(), "epic: a wrong code is refused, nothing kept")
    check(run("epic", "login", "nonsense with spaces").returncode == 1, "epic: text without a code is refused")
    r = run("epic", "login", '{"redirectUrl":"https://localhost/launcher/authorized?code=x","authorizationCode":"EPICGOODCODE0123456789","exchangeCode":null,"sid":null}', check_code=0)
    check("Signed in to Epic Games as EpicTester" in r.stdout, "epic: login with the page's text")
    check("secret" not in r.stdout + r.stderr, "epic: no token in the output")
    mode = (epic_state / "user.json").stat().st_mode & 0o777
    check(mode == 0o600 and (epic_state.stat().st_mode & 0o777) == 0o700, f"epic: the sign-in is private (file {oct(mode)})")
    check(json.loads(run("epic", "status", "--json").stdout)["user"] == "EpicTester", "epic: status after signing in")

    r = run("epic", "list", "--json", "--refresh", check_code=0)
    rows = json.loads(r.stdout)["games"]
    check([g["title"] for g in rows] == ["Alpha Quest", "Zeta Battle"], f"epic: list: Windows games Legendary can install, by title ({[g['title'] for g in rows]})")
    check(rows[0]["image"].endswith("epic_alphaquest_DieselGameBoxTall.jpg") and not rows[0]["installed"], "epic: list: the cover and the state")
    check(json.loads(run("epic", "folders", "--json").stdout)["folders"][0]["name"] == "mac", "epic: folders")
    check([g["year"] for g in rows] == [2015, 2021],
          f"epic: release years: the earliest PC date of the game's own offers, else the store date ({[g['year'] for g in rows]})")
    check(sorted(GQL_ASKED) == ["ns-alphaquest", "ns-zetabattle"], f"epic: the store was asked once per game ({GQL_ASKED})")
    n_asked = len(GQL_ASKED)
    rows = json.loads(run("epic", "list", "--json", "--refresh", check_code=0).stdout)["games"]
    check(len(GQL_ASKED) == n_asked and [g["year"] for g in rows] == [2015, 2021], "epic: a year that is found is kept, not asked again")
    (tmp / "state/epic-years.json").unlink()
    rows = json.loads(run("epic", "list", "--json", env={"BOTTLE_EPIC_GRAPHQL": "http://127.0.0.1:1/graphql"}, check_code=0).stdout)["games"]
    check([g["title"] for g in rows] == ["Alpha Quest", "Zeta Battle"] and [g["year"] for g in rows] == [0, 0],
          "epic: with the store out of reach the list still comes, without years")
    rows = json.loads(run("epic", "list", "--json", check_code=0).stdout)["games"]
    check([g["year"] for g in rows] == [2015, 2021], "epic: the years come when the store is back")

    # install
    r = run("epic", "install", "alphaquest", env={"FAKE_EPIC_FAIL": "space"})
    check(r.returncode == 1 and "Not enough available disk space" in r.stdout, f"epic: a failed check is explained ({r.stdout.strip()[-120:]})")
    check("alphaquest" not in json.loads((tmp / "state/games.json").read_text()).get("epic", {}), "epic: nothing recorded after a failure")
    check(run("epic", "install", "nosuchgame").returncode == 1, "epic: a game that can't be installed fails cleanly")
    check(run("epic", "install", "--evil").returncode != 0, "epic: an id that looks like an option is refused")
    check(run("epic", "install", "alphaquest", "--folder", "nope").returncode == 1, "epic: unknown folder refused")
    r = run("epic", "install", "alphaquest", check_code=0)
    out = r.stdout
    check("@@progress 25.0 10 40 00:00:03" in out and "@@progress 100.0 40 40" in out, f"epic: progress lines for the app ({out!r})")
    check("@@done alphaquest" in out, "epic: done line")
    check("Downloaded:" not in out and "Cache usage" not in out, "epic: noise left out")
    edest = mounts / "mac/Epic Games/AlphaQuest"
    check((edest / "Binaries/Win64/Game.exe").is_file(), "epic: game files in the default folder")
    erec = json.loads((tmp / "state/games.json").read_text())["epic"]["alphaquest"]
    check(erec["exe"] == str(edest / "Binaries/Win64/Game.exe") and erec["startdir"] == str(edest / "Binaries/Win64"),
          f"epic: exe found case-insensitively ({erec['exe']})")
    check(erec["title"] == "Alpha Quest" and erec["version"] == "1.0" and erec["store"] == "epic" and erec["size"] == 4242, "epic: record")
    ewant = (zlib.crc32((f'"{erec["exe"]}"' + "Alpha Quest").encode()) & 0xFFFFFFFF) | 0x80000000
    check(int(erec["appid"]) == ewant, "epic: shortcut app ID is crc32(quoted exe + name) | 0x80000000")
    check(all((art / f"epic-alphaquest_{k}").is_file() for k in ("cover.jpg", "hero.jpg", "logo.png", "icon.png")),
          "epic: cover, background, logo and icon fetched")
    check((art / "epic-alphaquest_hero.jpg").read_bytes() == b"\xff\xd8epic_alphaquest_DieselGameBox.jpg" + REV[0], "epic: the wide key art is the hero")
    check(erec["icon"].endswith("epic-alphaquest_icon.png") and erec.get("art") == 2, "epic: icon and the note that pictures are fetched")
    r = run("epic", "list", "--json", check_code=0)
    row = next(g for g in json.loads(r.stdout)["games"] if g["id"] == "alphaquest")
    check(row["installed"] and not row["update"] and row["size"] == 4242, "epic: list shows it installed, up to date")
    r = run("epic", "list", "--json", "--refresh", env={"FAKE_EPIC_VERSION": "1.1"}, check_code=0)
    row = next(g for g in json.loads(r.stdout)["games"] if g["id"] == "alphaquest")
    check(row["update"] is True, "epic: list shows an update when Epic has a newer version")
    run("epic", "list", "--refresh", check_code=0)

    # sync
    r = run("sync", check_code=0)
    check("1 added" in r.stdout, f"epic: sync adds the game ({r.stdout.strip()})")
    parsed = mod.bvdf_load((udir / "shortcuts.vdf").read_bytes())["shortcuts"]
    entry = next(e for e in parsed.values() if mod.sval(e, "AppName") == "Alpha Quest")
    check(mod.sval(entry, "ShortcutPath") == "portalistic:epic:alphaquest" and entry["tags"]["0"] == (1, "Epic Games"), "epic: marker and collection")
    check(mod.sval(entry, "LaunchOptions") == "/usr/local/bin/bottle-stores run --epic alphaquest -- %command%", f"epic: launch options ({mod.sval(entry, 'LaunchOptions')})")
    others = [mod.sval(e, "AppName") for e in parsed.values()]
    check("My Own Game" in others, f"epic: the other shortcuts stay ({others})")
    for name in (f"{ewant}p.jpg", f"{ewant}_hero.jpg", f"{ewant}.jpg", f"{ewant}_logo.png"):
        check((grid / name).is_file(), f"epic: {name} is in the grid folder")
    check(str(ewant) in run("ids", check_code=0).stdout.split(), "epic: ids lists it")
    check(run("sync", check_code=0).stdout.strip() == "", "epic: a second sync changes nothing")

    # run: Epic's sign-in is added to the game's arguments
    out_file = tmp / "argv.json"
    prog = f"import sys, json; json.dump(sys.argv[1:], open({str(out_file)!r}, 'w')); sys.exit(3)"
    r = run("run", "--epic", "alphaquest", "--", sys.executable, "-c", prog, "-mine")
    got = json.loads(out_file.read_text())
    check(r.returncode == 3, f"epic: the game's exit code comes through ({r.returncode})")
    check(got == ["-mine", "-fromManifest", "-AUTH_LOGIN=unused", "-AUTH_PASSWORD=TOKEN123", "-AUTH_TYPE=exchangecode", "-epicapp=alphaquest"],
          f"epic: the game gets its own arguments, then Epic's ({got})")
    out_file.unlink()
    r = run("run", "--epic", "alphaquest", "--", sys.executable, "-c", prog, env={"FAKE_EPIC_LAUNCH": "offline-only"})
    check(json.loads(out_file.read_text())[-3:-2] == ["-AUTH_PASSWORD="], "epic: Epic unreachable: started offline")
    out_file.unlink()
    r = run("run", "--epic", "alphaquest", "--", sys.executable, "-c", prog, env={"FAKE_EPIC_LAUNCH": "fail"})
    check(r.returncode == 3 and json.loads(out_file.read_text()) == [], "epic: no launch arguments at all: the game still starts")
    elog = (tmp / "home/.cache/steamos-bottle/epic.log").read_text()
    check("Epic's sign-in added" in elog and "started offline" in elog and "started without Epic's sign-in" in elog, "epic: what happened is in epic.log")
    check("TOKEN123" not in elog + r.stdout + r.stderr, "epic: the token is never logged or printed")
    check(run("run", "--epic=--evil", "--", sys.executable, "-c", "pass").returncode == 0, "epic: an odd id doesn't stop the game")

    # remove
    run("epic", "remove", "alphaquest", check_code=0)
    check(not edest.exists(), "epic: files deleted")
    check("alphaquest" not in json.loads((epic_state / "installed.json").read_text()), "epic: Legendary's record forgotten")
    check("alphaquest" not in json.loads((tmp / "state/games.json").read_text())["epic"], "epic: record gone")
    check(not list(art.glob("epic-alphaquest_*")), "epic: our copies of the pictures taken out")
    run("sync", check_code=0)
    left = [mod.sval(e, "AppName") for e in mod.bvdf_load((udir / "shortcuts.vdf").read_bytes())["shortcuts"].values()]
    check("Alpha Quest" not in left and "My Own Game" in left, f"epic: shortcut taken out, others stay ({left})")
    check(not any((grid / f"{ewant}{suffix}").exists() for suffix in ("_hero.jpg", ".jpg", "p.jpg", "_logo.png")), "epic: grid pictures taken out")
    check(run("epic", "remove", "alphaquest").returncode == 1, "epic: removing twice says so")
    run("epic", "install", "zetabattle", check_code=0)
    zg = json.loads((tmp / "state/games.json").read_text())
    other2 = tmp / "precious2"
    other2.mkdir()
    (other2 / "keep.txt").write_text("x")
    zg["epic"]["zetabattle"]["dir"] = str(other2)
    (tmp / "state/games.json").write_text(json.dumps(zg))
    run("epic", "remove", "zetabattle", check_code=0)
    check((other2 / "keep.txt").exists(), "epic: never deletes outside an Epic Games folder")

    # sign out and in again (a bare code works too); installed games stay
    run("epic", "logout", check_code=0)
    check(not (epic_state / "user.json").exists() and json.loads(run("epic", "status", "--json").stdout)["signedIn"] is False, "epic: logout forgets the sign-in")
    check("Signed in" in run("epic", "login", "EPICGOODCODE0123456789", check_code=0).stdout, "epic: a bare code works")
    # a sign-in that has run out counts as signed out
    ud = json.loads((epic_state / "user.json").read_text())
    ud["refresh_expires_at"] = "2001-01-01T00:00:00.000Z"
    (epic_state / "user.json").write_text(json.dumps(ud))
    check(json.loads(run("epic", "status", "--json").stdout)["signedIn"] is False, "epic: an expired sign-in counts as signed out")
    # a failed new sign-in keeps the old one
    ud["refresh_expires_at"] = "2099-01-01T00:00:00.000Z"
    (epic_state / "user.json").write_text(json.dumps(ud))
    run("epic", "login", "WRONGCODE0123456789")
    check(json.loads(run("epic", "status", "--json").stdout)["signedIn"] is True, "epic: a refused code leaves the earlier sign-in alone")

    # the real Legendary in the kit starts under the same bootstrap (needs requests, filelock and pycryptodomex)
    try:
        import requests, filelock, Cryptodome  # noqa: F401
        have_deps = True
    except ImportError:
        have_deps = False
    if have_deps:
        e = dict(os.environ, PYTHONPATH=str(HERE.parent / "stores"), LEGENDARY_CONFIG_PATH=str(tmp / "lgd-real"), PYTHONDONTWRITEBYTECODE="1")
        r = subprocess.run([sys.executable, "-c", mod.LGD_BOOT, "--version"], capture_output=True, text=True, env=e, timeout=120)
        check(r.returncode == 0 and "0.21.1" in r.stdout, f"epic: the Legendary in the kit starts ({r.stdout.strip()[:60]}{r.stderr.strip()[-100:]})")
        e2 = dict(ENV, BOTTLE_LEGENDARY="", BOTTLE_LEGENDARY_DIR=str(HERE.parent / "stores"), PYTHONDONTWRITEBYTECODE="1")
        r = run("epic", "status", "--json", env=e2, check_code=0)
        check(json.loads(r.stdout)["downloader"] is True, "epic: the tool finds the kit's Legendary")
    else:
        print("skip  the real Legendary needs requests, filelock and pycryptodomex")

    # logout
    run("gog", "logout", check_code=0)
    check(not (tmp / "state/gog-auth.json").exists(), "logout forgets the sign-in")
    print("\nALL PASSED" if not failures else f"\n{len(failures)} FAILED: {failures}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
