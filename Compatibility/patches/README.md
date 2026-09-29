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

## `native-message-boxes.patch`

PorTalistic's own. A Windows message box (`MessageBox` and everything built on it:
`MessageBoxEx`, `MessageBoxIndirect`, `ShellMessageBox`, `FatalAppExit`) comes up as a
native macOS alert instead of the dialog Wine draws itself, in Tahoma with Windows buttons.
Applied after `wineandaqua-dxmt.patch`, which it is written against.

**How.** user32 still builds, initialises and runs the message box's dialog exactly as
before: it disables the owner, honours `MB_TASKMODAL`, and is what `MessageBox` gets its
answer from. Once the dialog is ready, user32 offers it to the display driver with a
driver-range message, `WM_WINE_NATIVE_MSGBOX`. The Mac driver reads the caption, text and
buttons back out of the dialog (so Wine's translations come along, and so does anything a
program changed first, like relabelled buttons) and shows an `NSAlert`. The dialog stays
hidden, and the button the user picks comes back as an `ALERT_RESPONSE` event and is posted
to the dialog as the `WM_COMMAND` a click on that button would have sent. If the program ends
the dialog itself first (`EndDialog`, `WM_CLOSE`), the alert goes with it. Any other driver
answers the message with 0 and nothing changes.

What an alert does that the dialog did: the first button is rightmost, where macOS puts the
primary action; Return presses the message box's default button, not necessarily the first;
Escape and ⌘-period answer Cancel if there is one and OK if that's the only button, and
nothing otherwise, as on Windows; ⌘C copies the caption and message. A key the game was
holding when the box came up (the Escape that opened it, say) doesn't answer it by repeating
into it, and Windows still sees that key let go. What it adds: it comes
up on the game's screen, above a fullscreen or topmost game window, and bounces in the Dock
if macOS won't bring the game forward. A message too long for an alert's label goes in a
scrolling view, so the buttons stay on screen.

**What stays Wine's own dialog.** A message box with a Help button (`MB_HELP`): Help keeps
the box open and sends `WM_HELP`, which an alert can't. And anything that isn't
`MessageBox`: `TaskDialog`, `SHMessageBoxCheck`, a program's own dialogs, Wine's crash
dialog.

**Switching it off.** `UseNativeMessageBoxes`, a string, `n` to turn it off: under
`HKCU\Software\Wine\Mac Driver` for a whole prefix, or under
`HKCU\Software\Wine\AppDefaults\<game>.exe\Mac Driver` for one program. On by default.

**Checked by** `build-dxmt-wine.sh`, which refuses a build without it in `winemac.so` and in
both `user32.dll`s, and `test-dxmt-wine.sh`, which answers a run of message boxes the way
programs do, 64-bit and 32-bit, with it on and with it off (`tests/msgbox-test.c`). The same
checks fail on a Wine without the patch, which is how they were checked.

**Only in this Wine.** Games on the bundled engine, Wine Stable or Sikarugir still get Wine's
dialog: those are prebuilt, and this is a change to Wine itself.

**Licence.** LGPL-2.1-or-later, like the Wine it patches.
