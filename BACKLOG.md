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
