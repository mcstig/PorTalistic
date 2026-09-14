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

## `Game` identity ignores the storefront

`Game.==` and `Game.hash(into:)` use `id` alone, and the library is a
`Set<Game>`. So an Epic game and a GOG game that happen to share an id are the
same game as far as the library is concerned: the second one merges into the
first and one of them disappears.

In practice it holds up — GOG's ids are numeric and Epic's are hex-ish
catalogue names — so nothing has collided yet. But nothing stops it, and
`library.first(where: { $0 == fetchedGame })` in `refreshFromStorefronts` will
match across storefronts if it ever happens. Identity should be
`(storefront, id)`; the reason to be careful about changing it is that `id`
alone is also what's persisted, so a migration has to keep existing libraries
readable.

Found while fixing the Epic add-on duplicates, which turned out to be the
opposite problem — distinct ids, same title — so this one is still only
theoretical.

## Epic sells things that aren't games, and Mythic shelves them as games

Filtering out add-ons left two entitlements that are neither games nor add-ons:
**Discord** and **Antstream Arcade**, both filed under Epic's `software`
category. They're in the library as cards with Play buttons.

They weren't filtered, on purpose. They are real, separately launchable things
the account owns, and hiding a purchase is the worse mistake — but a card that
looks exactly like a game is the wrong answer too. Epic's own launcher shelves
them apart, and so does Steam; Mythic should get a section for them rather than
either showing them as games or pretending they aren't owned.

Worth doing as part of the library UI pass, since it's a shelf, not a filter:
`software` in the category paths is the discriminator, already visible in the
metadata Mythic decodes.

## D3DMetal is out. DXMT is the plan, and it rests on one Wine build.

**The decision.** Apple's Game Porting Toolkit licence restricts distribution of
its proprietary components — `D3DMetal.framework` among them — to
non-commercial purposes. This is a Patreon-funded product, so Mythic cannot ship
it, and an Apple Developer account does not change that: it grants access to
*download* GPTK and the ability to sign and notarise an app, not permission to
redistribute Apple's binaries. So Direct3D 10 and newer goes through DXMT, which
is open source.

**What that costs, stated plainly.** DXMT only works on a Wine exposing
`winemac.drv`'s Metal escape interface, and exactly one build in the catalogue
has them: Sikarugir. Which is the build recorded above as sometimes unable to
create a container at all — every Windows process it starts killed by macOS the
moment Wine hands control to Windows code. So every Direct3D 11 and 12 game now
depends on a single third-party build with a known failure mode, where before it
depended on Apple's implementation being present.

That is a worse engineering position and a better legal one, and there is no
version of this that is both. Selection therefore keeps the engine reachable
*behind* DXMT rather than removing it: a machine that already has D3DMetal can
still use it, and a fallback that works beats a principle that doesn't.

**What still needs deciding, and is not decided by the above:**

  - **The engine is itself GPTK-derived and carries D3DMetal.** Mythic does not
    bundle it — it downloads it from `dl.getmythic.app`, upstream's server — so
    this build redistributes nothing today. Whether pointing a paid product at
    someone else's download for a non-commercially-licensed component is
    acceptable is a question for a lawyer, not for this file. It is also a
    product risk independent of licensing: the core runtime of a paid product
    comes from a server this project does not control.
  - **A second DXMT-capable Wine build would remove the single point of failure.**
    Either another published build with the escapes, or building one. This is the
    highest-value item on this list now, because everything modern depends on it.
  - ~~**Use the user's own GPTK when they have one.**~~ Done:
    ``Wine/D3DMetal/isPresent(in:)`` detects `lib/external/D3DMetal.framework`,
    so a Game Porting Toolkit or Whisky install is now recognised and chosen
    behind DXMT. Mythic detects and never installs.

## Per-game settings: the half that isn't applied yet

`Provisioner.apply(_:to:)` writes the three settings that live in a container's
registry — Retina Mode, CSMT, Windows version — and reverts them after. The other
four a profile can carry don't move: `msync`, `metalHUD`, `avx2` and `dxvk` are
read from the container's *persisted* settings when a launch assembles its
environment, so overriding them per game means writing to the container and
hoping to write back, and a crash mid-game would leave someone's container
changed.

The right place for those is environment assembly:
`Wine.assembleEnvironmentVariables(forContainerAtURL:)` should take an optional
overlay, so a game's values are used for that process and nothing is persisted or
has to be put back. `dxvk` is different again — it's DLLs in the prefix, not an
environment variable — and probably belongs to the container rather than the game.

Also outstanding: only GOG's Windows launch goes through `planLaunch`. Epic and
Local still read `game.containerURL` directly, so they neither get the right
runtime nor per-game settings. Same three lines each.

## The interface pass: what it left behind

The pass built a design system (`Views/DesignSystem/`) and rebuilt the sidebar, Home, the
game card, the list row and — new — a game page. Surfaces are now asked for by role
(`floatingSurface`, `cardSurface`, `artworkScrim`, `artworkFadesOut`) and `Surfaces.swift`
decides how each role is drawn on the running system, instead of eighteen inlined
`#available(macOS 26.0, *)` checks that had drifted apart.

Not finished:

  - **Nine of those checks are still inlined**, in `OperationCard` (four),
    `OperationsView`, `RosettaInstallationView`, `GameSettingsView`,
    `EpicGamesGameImportView`, `EngineInstallationView`, `OnboardingView` and
    `HeroGameCard`. They should ask for a role too. `OperationCard` is the one a
    user sees, and it still draws its own glass panels by hand.
  - **The pre-macOS-26 appearance has never been seen on a machine that renders
    it.** This one runs Tahoe, so `#available(macOS 26.0, *)` is always true here
    and the fallback half of `Surfaces.swift` is dead code locally. Settings ▸ View
    has a debug switch — "Draw the pre-macOS 26 appearance" — which forces
    `FloatingSurface` down the other path; it does *not* force the `macOS 15`
    branches, and nothing forces AppKit's own Tahoe-era control rendering. A real
    Sonoma or Sequoia machine is still the only way to know.
  - **Toolbar visibility leaks between `NavigationStack` destinations.** Home hides
    the title bar's background so artwork can run under it, and every sibling
    inherits that until it says otherwise — hence `standardTitleBar()` on
    `LibraryView`. Upstream fought the same bug with the same kind of workaround.
    Worth revisiting if SwiftUI ever scopes this properly.
  - **`GameArtwork` re-requests on `.task`, not on appearance.** `ArtworkCache`
    keeps decoded covers for the life of the process, which is what stopped the
    library dissolving back in on every navigation, but nothing persists across
    launches beyond `URLCache`'s bytes, so the first paint of a cold launch still
    decodes 136 JPEGs. A small on-disk thumbnail cache would fix that.
  - **`HeroGameCard` is still an `EmptyView()` stub** with a `#Preview` that
    describes what it was going to be. `HomeHero` in `HomeView` is the thing that
    got built. Delete the stub or move `HomeHero` into it.
  - **`StoreView` renders as a blank rectangle** when Epic's page doesn't load —
    no loading state, no empty state, no way to tell a slow network from a broken
    view.
  - **The grid is the only layout with hover owned by its container.** `GameCard`
    takes a `hoveredGameID` binding because `.onHover` in a `LazyVGrid` does not
    reliably deliver the exit event, and a card that keeps its own flag gets stuck
    showing its Play button while the pointer is elsewhere. `ListGameCard` still
    keeps its own — rows are full width, so it is much harder to trip, but it is
    the same latent bug.

  - **Hover-revealed controls are invisible to VoiceOver.** `revealedOnHover` leaves
    them hit-testable only while hovered but deliberately does not set
    `accessibilityHidden`, on the theory that an AX press reaches an element
    directly. In practice AppKit appears to drop zero-opacity views from the
    accessibility tree anyway — searching the grid for an "Install" element finds
    nothing. So Play and Install are unreachable without a pointer. The fix is to
    put them in the context menu as well, which means the card owning an install
    flag and the launch-error alert the way it already owns the settings and
    uninstall flags. Hover is not a gesture every user has.

## The design system's remaining gaps

Buttons, sheet surfaces and panels are routed through `Views/DesignSystem/` now, which
carried the look into most of the app for free. What it did not reach:

  - ~~The Settings window~~, ~~Containers~~, ~~Onboarding~~ and ~~the installation
    sheets' headers~~ are done. What's left below.
  - **`ContainerCreationView` and `ContainerSettingsView`** have the app's ground
    and buttons but their own layout inside.
  - **`GameSettingsView`**, which is where a per-game runtime override will have to
    live once `RuntimeProfile.Source.userOverride` is reachable from the interface.
    Also `HarmonyRatingView`, `RosettaInstallationView`, `EngineInstallationView`,
    and the four `GameImportView` tabs below their new chrome.
  - **`SteamGameImportView`'s `Spacer()`** has the same shape as the bug that made
    the GOG import tab appear blank — it is only safe because the tab container
    now proposes an ordinary height. Worth removing on principle.

Also outstanding from this round:

  - **`Button("Cancel", role: .cancel)` comes out solid violet** like everything
    else, because the sheet sets one default style for every unstyled button in it.
    That is what "all buttons purple" asks for, but Cancel competing with Done for
    attention is worth a second look.
  - **Four `#available(macOS 26.0, *)` checks remain**, in `RosettaInstallationView`,
    `GameSettingsView`, `EpicGamesGameImportView`, `EngineInstallationView` and
    `OnboardingView`. `OperationCard`'s four are gone.
  - **`HeroGameCard` is still an `EmptyView()` stub.**

  - **The sidebar no longer has arrow-key navigation.** It stopped being a `List`
    (see the commit for why), and a `ScrollView` of buttons doesn't move selection
    with the arrow keys. Restoring it means `onMoveCommand` on a focusable
    container, plus deciding what focus looks like in there.
