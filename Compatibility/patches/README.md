# Patches

## `wineandaqua-dxmt.patch`

Aquadran's patch to Wine's `dlls/winemac.drv`, by way of
[macgameport/cities-skylines-2-macos](https://github.com/macgameport/cities-skylines-2-macos).
Pinned at SHA-256 `f470d52d3deac16f2f210e32f914b6190ceb2218deae86c8078edb2d31494130`;
`build-dxmt-wine.sh` fetches it once, verifies that digest, and leaves it here.

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

**Licence.** Wine is LGPL-2.1+ and this patch is compatible with it. Publishing a build
made from them means publishing the corresponding source, which is what pinning the
tarball and keeping the patch here is for. Nothing in this path involves Apple's Game
Porting Toolkit or `D3DMetal.framework`, whose licence is non-commercial only, or any
CrossOver binary.
