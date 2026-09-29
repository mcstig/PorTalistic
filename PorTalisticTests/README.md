# PorTalisticTests

Regression tests. Every test in here stands for something that reached a user, and most of
them stand for something that reached a user *twice*.

The rule: **when a fault is fixed, the thing that would have caught it goes in the same
commit.** Not a test for the feature — a test for the fault, named after what went wrong, so
that the failure message is the diagnosis. `"A stored DPI cannot contradict Retina Mode"`
says more at 2am than `testDisplayScaling`.

## What is where

| File | The faults it stands for |
| --- | --- |
| `ContainerSettingsRegressionTests` | Games opening in a quarter-size window, three times, because a prefix's DPI and its Retina Mode disagreed |
| `WineEnvironmentRegressionTests` | Two wine icons in the Dock and no game: the wine-mono dialog nothing clicks, and a `wineserver` running with the msync setting a previous launch left behind |
| `RuntimeProfileRegressionTests` | Retina Mode on by default, which gave one game a quarter of a 4096×2660 desktop and blanked the other display; curated entries that don't say why they exist |
| `AutomaticSettingsRegressionTests` | Automatic settings reading, or losing, what the user set by hand; games whose platform was never recorded getting no profile at all |
| `LibraryFilterRegressionTests` | Picking Steam — hidden, no games — emptying the library with no way back, because the controls that undo a filter were hidden by that filter. And the library's order: A to Z and Z to A the way people read names, installed games first unless that's switched off |
| `ExternalVolumeRegressionTests` | "PorTalistic would like to access files on a removable volume", on every launch; and an unplugged SSD destroying a GOG install record |
| `GamePersistenceRegressionTests` | A storefront refresh un-installing a game it couldn't see, and resetting settings someone had set by hand |
| `RenderPathRegressionTests` | A full-screen library scrolling at 296 card bodies a second, because a view storing a `Binding` can never be skipped; and every card redrawn at the start of every scroll by a hover write that changed nothing |
| `RebrandRegressionTests` | Force Quit listing a game as `BioshockHD.exe (Mythic)`: the engine names every Windows process after upstream, and the rename that corrects it has to keep the executable's name and leave other apps' Wine alone. And the default install folder's rename, which must not move a library out from under its games |
| `LaunchLifecycleRegressionTests` | A launch that ended with `legendary` rather than with the game: a six-second Play spinner, a Play button that started a second copy, a running game with no way left to stop it — and, once launches lasted, a library that reshuffled around the game being played. Plus the installs that quitting used to orphan, and the badge a stopped download left on the Dock icon |

## Running them

    xcodebuild test -scheme PorTalistic -destination 'platform=macOS'

or ⌘U in Xcode.

## Two things to know

**The suite is hosted by the app**, so the app launches to run it. `AppDelegate.isRunningTests`
short-circuits `applicationDidFinishLaunching` — without that, every run would migrate
folders, start provisioning runtimes, talk to Epic and GOG, and rewrite the library in
`UserDefaults`. A test suite that edits the thing it is testing is worse than no test suite.
Anything added to launch that has side effects belongs behind that guard.

**Not everything here is testable this way.** A rule with two copies of itself, a `FileManager`
call added to a view that draws three hundred times a second, a second hardcoded Play button
— those are properties of the source, and they are checked by `Scripts/check-invariants.sh`,
which also runs as a build phase and reports violations as Xcode warnings. Anything past
`planLaunch` runs wine and is covered by neither; the self-built Wine verifies its own
freetype install name in `Compatibility/build-dxmt-wine.sh`.

**A green suite proves nothing on its own.** A test is green either because the code is right
or because the test doesn't look at it, and the two are indistinguishable until you break the
code on purpose. `Scripts/verify-suite-bites.sh` puts each fault back as a one-line edit,
runs the suite, and reports which test caught it — restoring every file and checking the
restore against its SHA-256 as it goes. When you add a test here, add its mutation there.
