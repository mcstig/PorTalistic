#!/usr/bin/env python3
"""Self-test for bottle-dxvk's Proton and prefix passes, on a made-up Steam folder.

Covers the Oct 14 failure: after Steam updates Proton, its new (read-only) DXVK DLLs have to
replace our copies, and Proton's earlier originals kept as <dll>.bottle-orig are read-only too.
Run: python3 guest/tests/dxvk-selftest.py   (no root, no Steam needed)
"""
import importlib.machinery
import importlib.util
import os
import stat
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
KIT = HERE.parent


def load(home, steam, cache, vkd3d):
    os.environ["HOME"] = str(home)
    os.environ["BOTTLE_STEAM_DIR"] = str(steam)
    os.environ["BOTTLE_DXVK_DIR"] = str(cache)
    loader = importlib.machinery.SourceFileLoader("bottle_dxvk", str(KIT / "bottle-dxvk"))
    spec = importlib.util.spec_from_loader("bottle_dxvk", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    mod.VKD3D_CACHE = vkd3d
    return mod


def write(path, data, mode=0o555):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        path.chmod(0o644)
        path.unlink()
    path.write_bytes(data)
    path.chmod(mode)


failures = []


def check(cond, what):
    print(("ok:   " if cond else "FAIL: ") + what)
    if not cond:
        failures.append(what)


def main():
    with tempfile.TemporaryDirectory() as t:
        t = Path(t)
        home, steam, cache, vkd3d = t / "home", t / "steam", t / "cache", t / "vkd3d"
        home.mkdir()
        proton = steam / "steamapps/common/Proton - Experimental"
        write(proton / "proton", b"#!/bin/sh\n", 0o755)
        dirs = {"x64": proton / "files/lib/wine/dxvk/x86_64-windows", "x32": proton / "files/lib/wine/dxvk/i386-windows"}
        vdirs = {"x64": proton / "files/lib/wine/vkd3d-proton/x86_64-windows", "x32": proton / "files/lib/wine/vkd3d-proton/i386-windows"}
        dlls = ["d3d8.dll", "d3d9.dll", "d3d10core.dll", "d3d11.dll", "dxgi.dll"]
        vdlls = ["d3d12.dll", "d3d12core.dll"]
        for arch in ("x64", "x32"):
            for d in dlls:
                write(cache / arch / d, f"OURS dxvk {arch} {d}".encode(), 0o644)
            for d in vdlls:
                write(vkd3d / {"x64": "x64", "x32": "x86"}[arch] / d, f"OURS vkd3d {arch} {d}".encode(), 0o644)

        def proton_update(version):
            for arch, d in dirs.items():
                for dll in dlls:
                    write(d / dll, f"PROTON {version} DXVK {arch} {dll}".encode())
            for arch, d in vdirs.items():
                for dll in vdlls:
                    write(d / dll, f"PROTON {version} vkd3d {arch} {dll}".encode())

        # a game's prefix with the DXVK Proton put there (the Wine builtin check wants "DXVK" inside)
        pfx = steam / "steamapps/compatdata/42/pfx/drive_c/windows"
        def prefix_update(version):
            for rel, arch in (("system32", "x64"), ("syswow64", "x32")):
                for dll in dlls:
                    write(pfx / rel / dll, f"PROTON {version} DXVK prefix {arch} {dll}".encode(), 0o644)

        proton_update("1")
        prefix_update("1")
        m = load(home, steam, cache, vkd3d)

        def once():
            stamps = {}
            builtin = {}
            return (m.apply_proton(stamps, True), m.apply_prefixes(stamps, builtin, True), m.apply_vkd3d(stamps, builtin, True))

        r = once()
        check(r[0] == 2 and r[1] == 2 and r[2] == 2, f"first pass changes Proton, prefix and vkd3d folders {r}")
        for arch, d in dirs.items():
            check((d / "d3d11.dll").read_bytes().startswith(b"OURS"), f"our DXVK in Proton [{arch}]")
            check((d / "d3d11.dll.bottle-orig").read_bytes().startswith(b"PROTON 1"), f"Proton 1's DXVK kept [{arch}]")
        for arch, d in vdirs.items():
            check((d / "d3d12core.dll").read_bytes().startswith(b"OURS"), f"our vkd3d in Proton [{arch}]")

        # Steam updates Proton: new read-only DLLs, the old .bottle-orig files stay behind
        proton_update("2")
        prefix_update("2")
        check(not os.access(dirs["x64"] / "d3d11.dll.bottle-orig", os.W_OK) or os.geteuid() == 0,
              "the old original is read-only (as on the Mac)")
        r = once()
        check(r[0] == 2 and r[1] == 2 and r[2] == 2, f"second pass, after the Proton update, finishes {r}")
        for arch, d in dirs.items():
            for dll in dlls:
                check((d / dll).read_bytes().startswith(b"OURS"), f"our DXVK back in Proton [{arch}] {dll}")
            check((d / "d3d11.dll.bottle-orig").read_bytes().startswith(b"PROTON 2"), f"Proton 2's DXVK is the kept original [{arch}]")
        for arch, d in vdirs.items():
            check((d / "d3d12.dll").read_bytes().startswith(b"OURS"), f"our vkd3d back in Proton [{arch}]")
            check((d / "d3d12.dll.bottle-orig").read_bytes().startswith(b"PROTON 2"), f"Proton 2's vkd3d is the kept original [{arch}]")
        for rel in ("system32", "syswow64"):
            check((pfx / rel / "dxgi.dll").read_bytes().startswith(b"OURS"), f"prefix {rel} has our DXVK")

        # nothing to do the third time
        r = once()
        check(r == (0, 0, 0), f"third pass changes nothing {r}")

        # one file that can't be written must not stop the others
        proton_update("3")
        if os.geteuid() != 0:
            dirs["x64"].chmod(0o555)   # no new files in the x64 folder at all
            try:
                r = once()
            finally:
                dirs["x64"].chmod(0o755)
            check((dirs["x32"] / "d3d11.dll").read_bytes().startswith(b"OURS"), "x32 done although x64 couldn't be written")
            r = once()
            check((dirs["x64"] / "d3d11.dll").read_bytes().startswith(b"OURS"), "x64 done on the next pass")

        # remove puts Proton's DLLs back
        m.remove_proton_and_prefixes({})
        check((dirs["x64"] / "d3d11.dll").read_bytes().startswith(b"PROTON 3"), "remove puts Proton's DXVK back")

    if failures:
        print(f"\n{len(failures)} FAILED")
        sys.exit(1)
    print("\nALL PASSED")


main()
