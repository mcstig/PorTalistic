# Patches

## `wineandaqua-dxmt.patch`

Aquadran's patch to Wine's `dlls/winemac.drv`, by way of
[macgameport/cities-skylines-2-macos](https://github.com/macgameport/cities-skylines-2-macos).
Pinned at SHA-256 `f470d52d3deac16f2f210e32f914b6190ceb2218deae86c8078edb2d31494130`;
`build-dxmt-wine.sh` fetches it once, verifies that digest, and leaves it here.

It is CodeWeavers' own work — `dxmt_objc.h` is headed *Copyright 2025 Brendan Shanks for
CodeWeavers, Inc.*, LGPL-2.1-or-later — which is consistent with DXMT's own guide saying a
FOSS CrossOver Wine built from CodeWeavers' published sources is sufficient. That is a
better provenance than "a patch from a game repository".

It adds `dxmt_objc.h` / `dxmt_objc.m` and edits `cocoa_window.m`, `event.c`, `window.c`,
`macdrv.h`, `macdrv_cocoa.h`, `macdrv_main.c` and the driver `Makefile.in` — client
surfaces, `macdrv_view_create_metal_view`, `macdrv_view_get_metal_layer`, and a
`CLIENT_SURFACE_PRESENTED` event. Nothing outside `dlls/winemac.drv` is touched.

**Why it is needed.** DXMT is two halves. `winemetal.so` issues the Metal commands and
DXMT ships it. The other half is presentation: something has to hand a Wine window's swap
chain a `CAMetalLayer`, and stock `winemac.drv` will not. Dropping DXMT's prebuilt release
into Gcenx's Wine Stable 11 creates a device happily and then fails every swap chain with
`EGL_BAD_ALLOC` — that was tried on the author's machine and is written up in
`RuntimeSelection.swift`. Sikarugir's engine has the hooks but cannot boot a prefix on that
machine at all. Hence building one.

**It is x86_64-only, and that is load-bearing.** Everything `dxmt_objc.h` declares sits
inside `#if defined(__x86_64__)`. Build Wine's unix side as arm64 on an Apple Silicon Mac
and the patch compiles to nothing, then `cocoa_window.m` fails on `use of undeclared
identifier 'WineMetalLayer'`. The guard is correct: DXMT ships `winemetal.so` as x86_64, a
unix library cannot load into an arm64 unix side, and both engines that work on the author's
machine are x86_64-only under Rosetta. So the build passes `--host=x86_64-apple-darwin` and
`-arch x86_64`, and `build-dxmt-wine.sh` refuses to finish if `winemac.so` comes out any
other architecture.

**Licence.** Wine is LGPL-2.1+ and this patch is compatible with it. Publishing a build
made from them means publishing the corresponding source, which is what pinning the
tarball and keeping the patch here is for. Nothing in this path involves Apple's Game
Porting Toolkit or `D3DMetal.framework`, whose licence is non-commercial only, or any
CrossOver binary.
