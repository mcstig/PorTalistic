# Backlog

Things worth building, and what we already know that feeds them. Ordered by when they were
raised, not by priority.

---

## Pick the runtime for the user

**The ask:** when someone launches a game, Mythic chooses the Wine runtime or Mac porting
toolkit that will run *that* game best. The user never opens a menu to do it.

**Why it isn't cosmetic.** Runtimes are not better and worse versions of each other; they
fail in different directions, and which one you want depends entirely on the game:

- The bundled engine is Game Porting Toolkit derived and carries Apple's D3DMetal, so
  Direct3D 11 games render. It is also Wine 7.7, and its socket layer is old enough that
  anything network-heavy trips over it constantly.
- Mainline Wine 11 has four years of fixes and working sockets, and only wined3d — which on
  macOS sits on OpenGL 2.1. That means Direct3D feature level 9_3 and an adapter that claims
  to be an NVIDIA GeForce 6800. Modern Direct3D games get nothing.
- DXMT supplies Direct3D 11 on Metal, but only on a Wine exposing `winemac.drv`'s Metal
  entry points. On a Wine without them it half-works in the worst way: device creation
  succeeds, everything looks right, and every swap chain fails with `EGL_BAD_ALLOC`.

So "newest" is the wrong default, and so is "bundled". A 2005 2D game wants working
networking; a Direct3D 11 game wants D3DMetal; an anti-cheat game wants neither because it
won't run at all.

**What exists to build on:**

- `Runtime` already discovers every runtime on the machine — bundled, the ones Mythic
  installs, and Game Porting Toolkit / Whisky / CrossOver installs belonging to other apps.
- `RuntimeRelease.catalogue` is ordered by preference and pinned by digest, and each entry
  has a `summary` describing what it's good and bad at.
- Containers already record their runtime by id (`Container.Settings.runtimeID`), and fall
  back gracefully when that runtime is gone. Per-game selection is the same mechanism at a
  finer grain.
- `Wine.DXMT.isInstalled(in:)` / `isShippedByRuntime(_:)` answer "does this runtime have
  Direct3D 11 on Metal", which is the single biggest input to the decision.

**Open questions:**

- Where the compatibility data comes from. ProtonDB is keyed by Steam appid and is about
  Proton on Linux, so it transfers only partly. Mythic may need its own small database,
  seeded by hand and grown from what users report.
- Whether the choice is made once at install time (and stored with the game) or re-evaluated
  at launch. Storing it is kinder to the user — a game that worked yesterday works today —
  but then a better runtime arriving never helps existing games without a nudge.
- What the user sees. It should be automatic, but not silent: if Mythic picks something
  unusual, the game's settings should say which and why, and let them override it.

---

## Steam, if it comes back

Currently hidden behind `Steam.isEnabled` — the code is all there, nothing was deleted. See
that flag's documentation for why, in detail. Short version: the Windows client's UI cannot
be composited onto a Wine window, and every way of signing in without that UI has been
retired by Valve.

If it returns, it should return as `steamcmd` rather than the client: it authenticates
natively in seconds (including the phone confirmation), lists the library, and downloads
Windows depots directly, leaving Mythic to launch the game executables. The cost is
Steamworks — cloud saves, achievements, the overlay and some multiplayer — for games that
hard-require a running client.

## Fullscreen that actually fills the screen

Fixed for GOG in `GOGGameManager.launch`, and written down here because Epic
and Local still have it.

A game launched from Mythic came up in a window the size of its fullscreen
resolution, however its own settings were set. Wine's Mac driver doesn't
change the display mode while its process isn't the active application — it
records the request and applies it on activation. Mythic stayed in front, so
the game asked for fullscreen, was quietly told "later", and drew a window.
Changing any video setting in-game fixed it permanently, which is the tell:
by then the player had clicked into the game, so it was active and the
deferred mode change landed.

`Wine.handOverForeground(toGameNamed:startedAs:hidingLauncher:)` steps Mythic
aside and brings the game forward. Still to do:

  - Epic. `Legendary.launch` hands off to legendary, which spawns Wine
    detached — the process Mythic can see isn't the one that owns the window,
    so the name match is all there is to go on. Worth doing carefully.
  - Local Windows games, which share `LocalGameManager.launch` and the same
    misplaced `defer` that raised Mythic's own window immediately after
    queueing rather than after the game exited.
  - Matching the container's desktop resolution to what games actually ask
    for, which turns out to matter far more than sharpness. See below.

## Don't let a fullscreen game black out the other monitors

Once games started reaching fullscreen properly, a second monitor went black
for as long as the game ran. That is `winemac.drv` doing exactly what it is
written to do. In `cocoa_app.m`, `-setMode:forDisplay:`:

    if ([self mode:mode matchesMode:currentMode]) // Already there!
        return TRUE;
    ...
    if ([originalDisplayModes count] || displaysCapturedForFullscreen ||
        !active || CGCaptureAllDisplays() == CGDisplayNoErr)

A display-mode change by an active Wine process captures *every* display, not
the one being changed — and a captured display nothing is drawing to is black.
This is unconditional; `CaptureDisplaysForFullscreen` is a different lever and
doesn't turn it off.

The escape is the line above it: if the mode a game asks for already matches
the display's current mode, Wine returns before capturing anything. So the fix
is not a Wine setting, it's making those two numbers agree:

  - Retina Mode on puts the Wine desktop at the display's backing resolution
    (4096×2660 here). A game set to the point resolution (2048×1330) is asking
    for a different mode, so every display gets captured.
  - Retina Mode off puts the Wine desktop at 2048×1330, which is what games
    pick by default, so there is usually no mode change at all — fullscreen
    fills the screen, the other monitors stay lit, and nothing is captured.

Which suggests Mythic's default is wrong: Retina Mode defaults on, and the
cost of that is not softness, it's blanked monitors and a game that doesn't
fill the screen. At minimum the setting should say what it actually trades.
Better: before launching, compare the resolution the game last ran at (it is
in the game's own config — Prey's is `r_Width`/`r_Height` in `game.cfg`) with
the container's desktop mode, and offer to reconcile them. Belongs with
automatic runtime selection above.

## These settings are per-container. The right value is per-game.

Demonstrated, not theorised, in one evening on one machine with two games:

  - **Prey** wants Retina Mode off. On, its 2048×1330 fullscreen is a quarter
    of a 4096×2660 desktop and every display gets captured.
  - **Blades of Time** ran — windowed, wrongly sized, blanking the second
    monitor — with Retina Mode on, and started crashing with it off. Same
    container, same change, opposite outcome. Turning it off is what finally
    let it reach wined3d's fullscreen path, which is different code from the
    windowed one, and that is where it dies.

So the container is the wrong place for this. Two games in the same prefix
wanted opposite settings within an hour of each other, and a player who fixes
one breaks the other with no way to tell which change did it. The same will be
true of CSMT, MSync, and DXVK.

What this needs:

  - Per-game overrides layered over the container's settings, applied at
    launch and reverted after, so a container stays a container and a game's
    quirks travel with the game.
  - Somewhere to record *why* an override exists. "Retina Mode off" is
    meaningless in six months; "off, because on it renders a quarter of the
    screen" is not.
  - A shipped set of them for games known to need one, which is what every
    other launcher eventually grows and what the automatic runtime selection
    item above is really asking for.

And a rule for the launcher's own behaviour, learned the hard way: a container
setting that changes how games render is not a preference, it is a change of
environment. Changing one should say what it may affect and be easy to put
back, because the failure it causes will show up in a different game than the
one it was changed for.
