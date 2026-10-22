#!/usr/bin/env python3
"""bottle-libraries sync with a game folder that is a drive (made-up folders; BOTTLE_LIBRARIES_TEST=1 stands in
for the mount and the block device).  python3 libraries-disks-selftest.py [bottle-libraries]"""
import json, os, subprocess, sys, tempfile
from pathlib import Path

TOOL = sys.argv[1] if len(sys.argv) > 1 else str(Path(__file__).resolve().parent.parent / "bottle-libraries")
fails = []


def check(name, cond, extra=""):
    print(("ok   " if cond else "FAIL ") + name + (f"  [{extra}]" if extra and not cond else ""))
    if not cond:
        fails.append(name)


def acf(appid, name, installdir, size=1000):
    return ('"AppState"\n{\n\t"appid"\t\t"%s"\n\t"name"\t\t"%s"\n\t"installdir"\t\t"%s"\n\t"SizeOnDisk"\t\t"%s"\n\t"StateFlags"\t\t"4"\n}\n'
            % (appid, name, installdir, size))


with tempfile.TemporaryDirectory() as t:
    t = Path(t)
    home, steam = t / "home", t / "home/.local/share/Steam"
    (steam / "steamapps").mkdir(parents=True); (steam / "config").mkdir()
    (home / ".config/steamos-bottle").mkdir(parents=True)
    root, froot = t / "mnt", t / "mnt-folders"
    src = froot / "mac"                      # the folder itself (the old share)
    (src / "steamapps/common/Dead Cells/data").mkdir(parents=True)
    (src / "steamapps/common/Dead Cells/deadcells.exe").write_text("exe")
    (src / "steamapps/common/Dead Cells/data/a.pak").write_text("pak" * 100)
    (src / "steamapps/appmanifest_588650.acf").write_text(acf("588650", "Dead Cells", "Dead Cells", 303))
    (src / "steamapps/compatdata/588650/pfx").mkdir(parents=True)
    (src / "steamapps/compatdata/588650/pfx/user.reg").write_text("reg")
    (src / "steamapps/common/Proton - Experimental").mkdir()
    (src / "steamapps/common/Proton - Experimental/toolmanifest.vdf").write_text("x")
    (src / "steamapps/appmanifest_1493710.acf").write_text(acf("1493710", "Proton Experimental", "Proton - Experimental"))
    (src / "libraryfolder.vdf").write_text('"libraryfolder"\n{\n\t"contentid"\t\t"123456789"\n\t"label"\t\t"Mac"\n}\n')
    (src / ".test-mounted").write_text("")
    mp = root / "mac"
    mp.mkdir(parents=True)
    (mp / ".test-disk").write_text("")       # the block device is there
    (home / ".config/steamos-bottle/libraries.json").write_text(json.dumps(
        {"default": "mac", "stamp": "1", "folders": [{"name": "mac", "label": "Mac", "path": "/Users/x/Games/Portalistic",
                                                      "disk": True, "free": 50 * 10 ** 9}]}))
    env = dict(os.environ, HOME=str(home), BOTTLE_STEAM_DIR=str(steam), BOTTLE_LIBRARY_ROOT=str(root),
               BOTTLE_FOLDER_ROOT=str(froot), BOTTLE_LIBRARIES_TEST="1",
               BOTTLE_PREFIX_ROOT=str(home / ".local/share/steamos-bottle/compatdata"))

    def run(*a):
        r = subprocess.run([sys.executable, "-I", TOOL, *a], env=env, capture_output=True, text=True)
        return r.returncode, r.stdout + r.stderr

    rc, out = run("sync")
    check("sync ends well", rc == 0, out)
    check("the drive is mounted (stand-in)", (mp / ".test-disk-mounted").exists(), out)
    check("Dead Cells moved into the drive, files intact", (mp / "steamapps/common/Dead Cells/data/a.pak").read_text() == "pak" * 100
          and (mp / "steamapps/appmanifest_588650.acf").is_file(), out)
    check("its prefix came along", (mp / "steamapps/compatdata/588650/pfx/user.reg").is_file())
    check("the folder's copy is gone, manifest too", not (src / "steamapps/common/Dead Cells").exists()
          and not (src / "steamapps/appmanifest_588650.acf").exists())
    check("the library's contentid kept", "123456789" in (mp / "libraryfolder.vdf").read_text())
    check("said so", "game(s) moved into the drive" in out, out)
    lf = (steam / "steamapps/libraryfolders.vdf").read_text()
    check("Steam's library list points at the drive's mount", str(mp) in lf, lf)
    check("the Steam tool (Proton) in the folder moved to the VM's disk, not the drive", (steam / "steamapps/appmanifest_1493710.acf").exists()
          or (mp / "steamapps/appmanifest_1493710.acf").exists(), out)

    rc, out = run("sync")
    check("second sync: nothing to move, ends well", rc == 0 and "moved into the drive" not in out, out)
    check("no prefix bind-mount for a drive", not (mp / "steamapps/compatdata/.test-bound").exists())

    # prefixes 0.7.0.8 copied to the VM's disk go back into the drive
    pr = home / ".local/share/steamos-bottle/compatdata/mac/601150/pfx"
    pr.mkdir(parents=True); (pr / "user.reg").write_text("dmc")
    rc, out = run("sync")
    check("prefixes from the VM's disk go back into the drive", (mp / "steamapps/compatdata/601150/pfx/user.reg").read_text() == "dmc"
          and not pr.exists(), out)

    # no drive attached (an older Mac side, or BOTTLE_GAME_DISKS=0): the folder itself, as before
    (mp / ".test-disk").unlink(); (mp / ".test-disk-mounted").unlink()
    (home / ".config/steamos-bottle/libraries.json").write_text(json.dumps(
        {"default": "mac", "stamp": "2", "folders": [{"name": "mac", "label": "Mac", "path": "/Users/x/Games/Portalistic"}]}))
    (mp / ".test-mounted").write_text("")
    rc, out = run("sync")
    check("plain share: sync as before", rc == 0, out)

    rc, out = run("tidy", "--free", "mac=1000")
    check("tidy runs", rc == 0, out)

print("\n" + ("ALL OK" if not fails else "FAILED: " + ", ".join(fails)))
sys.exit(1 if fails else 0)
