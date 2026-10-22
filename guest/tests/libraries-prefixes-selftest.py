#!/usr/bin/env python3
"""bottle-libraries sync: Proton's prefixes of a shared game folder kept on the VM's disk (made-up folders,
no real mount: BOTTLE_LIBRARIES_TEST=1 stands in for it).  python3 libraries-prefixes-selftest.py [bottle-libraries]"""
import json, os, subprocess, sys, tempfile
from pathlib import Path

TOOL = sys.argv[1] if len(sys.argv) > 1 else str(Path(__file__).resolve().parent.parent / "bottle-libraries")
fails = []


def check(name, cond, extra=""):
    print(("ok   " if cond else "FAIL ") + name + (f"  [{extra}]" if extra and not cond else ""))
    if not cond:
        fails.append(name)


with tempfile.TemporaryDirectory() as t:
    t = Path(t)
    home, steam, root = t / "home", t / "home/.local/share/Steam", t / "mnt"
    (steam / "steamapps").mkdir(parents=True)
    (steam / "config").mkdir()
    (home / ".config/steamos-bottle").mkdir(parents=True)
    mac = root / "mac"
    (mac / "steamapps/compatdata/588650/pfx/drive_c").mkdir(parents=True)
    (mac / "steamapps/compatdata/588650/pfx/creation_sync_guard").write_text("")
    (mac / "steamapps/compatdata/588650/pfx/user.reg").write_text("saved progress\n")
    (mac / "steamapps/compatdata/601150").mkdir()
    (mac / ".test-mounted").write_text("")
    (home / ".config/steamos-bottle/libraries.json").write_text(json.dumps(
        {"default": "mac", "stamp": "1", "folders": [{"name": "mac", "label": "Mac", "path": "/Users/x/Games/Portalistic"}]}))
    local = home / ".local/share/steamos-bottle/compatdata/mac"
    env = dict(os.environ, HOME=str(home), BOTTLE_STEAM_DIR=str(steam), BOTTLE_LIBRARY_ROOT=str(root),
               BOTTLE_LIBRARIES_TEST="1", BOTTLE_PREFIX_ROOT=str(home / ".local/share/steamos-bottle/compatdata"))

    def run(**extra):
        r = subprocess.run([sys.executable, "-I", TOOL, "sync"], env=dict(env, **extra), capture_output=True, text=True)
        return r.returncode, r.stdout + r.stderr

    rc, out = run(BOTTLE_LIBRARIES_TEST_BINDFAIL="1")
    check("mount fails: sync still ends well", rc == 0, out)
    check("mount fails: says the prefixes stay in the folder", "prefixes stay in the folder this time" in out, out)
    check("mount fails: this run's copies are taken back (the folder's own stay in use)", not (local / "588650").exists())
    check("(the folder's prefixes untouched)", (mac / "steamapps/compatdata/588650/pfx/user.reg").read_text() == "saved progress\n")

    rc, out = run()
    check("first sync: ends well", rc == 0, out)
    check("first sync: the existing prefixes copied to the VM's disk", (local / "588650/pfx/user.reg").read_text() == "saved progress\n"
          and (local / "588650/pfx/creation_sync_guard").exists() and (local / "601150").is_dir(), out)
    check("first sync: mounted over the folder's compatdata", (mac / "steamapps/compatdata/.test-bound").read_text() == str(local), out)
    check("first sync: says so, with the count", "prefixes are on the VM's disk (2 copied there)" in out, out)
    check("no staging leftovers", not (local / ".copying").exists())
    check("the originals stay in the folder", (mac / "steamapps/compatdata/588650/pfx/user.reg").exists())

    rc, out = run()
    check("second sync while mounted: nothing done", rc == 0 and "prefix" not in out, out)

    # the VM restarted (no mount any more); a new game's prefix appeared in the folder meanwhile? (can't: Steam
    # starts after sync) - but an old one already copied must not be copied again
    (mac / "steamapps/compatdata/.test-bound").unlink()
    (local / "588650/pfx/user.reg").write_text("newer progress\n")
    rc, out = run()
    check("after a VM restart: mounted again, nothing copied again", "prefixes are on the VM's disk" in out and "copied" not in out, out)
    check("(the VM-disk copy keeps its newer progress)", (local / "588650/pfx/user.reg").read_text() == "newer progress\n")

    (mac / "steamapps/compatdata/.test-bound").unlink()
    rc, out = run(BOTTLE_LOCAL_PREFIXES="0")
    check("BOTTLE_LOCAL_PREFIXES=0: no mount", not (mac / "steamapps/compatdata/.test-bound").exists() and "prefix" not in out, out)

    # a prefix whose copy doesn't finish (a lost request): first time, nothing is mounted (try again later);
    # second time, the others are mounted and that game gets a new prefix
    (mac / "steamapps/compatdata/999").mkdir()
    (mac / "steamapps/compatdata/999/user.reg").write_text("x")
    rc, out = run(BOTTLE_LIBRARIES_TEST_COPYFAIL="999")
    check("copy stuck, first time: not mounted, try again later", not (mac / "steamapps/compatdata/.test-bound").exists()
          and "trying again at the next Steam start" in out, out)
    check("(nothing half-copied left)", not (local / "999").exists() and not (local / ".copying").exists())
    rc, out = run(BOTTLE_LIBRARIES_TEST_COPYFAIL="999")
    check("copy stuck, second time: mounted, that game set up again", (mac / "steamapps/compatdata/.test-bound").exists()
          and "couldn't be copied twice" in out, out)
    check("(the stuck game's old prefix stays in the folder)", (mac / "steamapps/compatdata/999/user.reg").exists())
    (mac / "steamapps/compatdata/.test-bound").unlink()

    # a folder whose drive isn't connected: nothing
    (mac / ".test-mounted").unlink()
    rc, out = run()
    check("folder not connected: no mount", rc == 0 and not (mac / "steamapps/compatdata/.test-bound").exists(), out)

print("\n" + ("ALL OK" if not fails else "FAILED: " + ", ".join(fails)))
sys.exit(1 if fails else 0)
