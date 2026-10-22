# Portalistic: how it is built (the kit, the `bottle` command, the VM, the findings)

This is the developer's documentation and working log, moved out of the README on Oct 22, 2026 (the README is
the short user page now). Paths are relative to the kit folder (the repository root). Image: `host/AppIcon.png`.

Steam on an Apple Silicon Mac. Portalistic runs Valve's Steam client in a small Linux system on
your Mac, drawing with the Mac's GPU, and Steam plays Windows games through Proton.

**[Download the latest version](https://github.com/mcstig/PorTalistic/releases/latest)**

- Needs an Apple Silicon Mac with macOS 26 or newer and 8 GB of memory or more. The VM gets its
  share of it (4 GB on an 8 GB Mac, 8 GB on a 16 GB one); bigger games want a Mac with 16 GB.
- Unzip it and open Portalistic. Outside Applications it offers to move itself there and opens
  the copy. The first launch downloads its Linux system (a little over 2 GB), then Steam installs
  itself and asks you to sign in. To remove it all: Portalistic > Uninstall Portalistic.
- Games go in Games/Portalistic in your home folder. Game Folders > Add a Game Folder adds another
  folder or an external drive (Steam's own Add Drive can't see your Mac's drives; Portalistic
  offers a drive when you connect it). The Linux system's own drive (Steam's "Internal Drive") is 20 GB:
  Linux, Steam and Proton, not games.
- Some games won't run: those whose anti-cheat doesn't accept Proton or a VM, and some whose copy
  protection fails under x86 emulation. Portalistic doesn't work around either.
- It's experimental: the ARM64 Steam client it uses is a beta build from Valve.

Portalistic is free. If you'd like to support it: [Patreon](https://www.patreon.com/PorTalistic)
(also Portalistic > Support Portalistic on Patreon in the app).

Portalistic isn't affiliated with Valve. It's free software under the GNU GPL, version 3
([LICENSE.md](../LICENSE.md)); the software it includes and their licenses are in
[LICENSES.md](../LICENSES.md).

## How it works

Portalistic runs a "SteamOS bottle" on an Apple Silicon Mac: a krunkit (libkrun) Linux VM running
Valve's ARM64 Steam client, with the Mac's GPU reached through Venus and KosmicKrisp.
Windows games run through Proton, with their Direct3D turned into Vulkan by DXVK.

```
Windows game ─► Proton x86_64 (Wine) under FEX ─► DXVK ─► x86 Venus ─┐
x86 Linux game ─► FEX ─► x86 Venus ───────────────────────────────────┤
ARM64 Linux game ─► Venus ────────────────────────────────────────────┤
                                                                       ▼
   bottle layer (swapchain + DXVK stand-ins) ─► virtio-gpu ─► KosmicKrisp ─► Metal (Mac)
   frames ─► TigerVNC desktop ─► macOS Screen Sharing
```

Status: Abathor (Windows, Direct3D 11) plays at a steady 60 fps at 1920x1080 on an M4 Max.
The project was called SteamOS Bottle until Oct 12, 2026. The app is Portalistic.app now; the
VM (Lima instance `steamos-bottle`), its settings in `~/.config/steamos-bottle` and the `bottle`
command keep their names.
Everything here is experimental: krunkit is marked experimental by Lima, and the ARM64
Steam client is an unreleased public-beta build Valve made for the Steam Frame.

## Portalistic.app: the app for any Apple Silicon Mac (Oct 12)

The packaged app needs no Homebrew, Xcode, Vulkan SDK or Terminal. Everything it runs is inside it:
Lima, krunkit, libkrun with the VM's kernel, virglrenderer, the Vulkan loader and KosmicKrisp. The
download is about 50 MB zipped, 120 MB installed. On its first launch it says what it will
download and sets up with one click (`bottle setup`):

1. It downloads Portalistic's ready-made Linux image (2.3 GB, from the project's GitHub release,
   checked against its SHA-256) into `~/.portalistic/download`.
2. Lima makes the VM from it in `~/.portalistic/lima`: half the Mac's memory under 24 GB (4-8 GB),
   a third from 24 GB (8-16 GB), its performance cores, and a 20 GB disk (Linux, Steam and Proton)
   that takes Mac space only as it fills. No Mac folders are
   shared except the game folder `~/Games/Portalistic`. The image file is deleted afterwards.
3. The VM starts, brings itself up to the app's kit for its user (`deck`) in a few seconds, and
   installs Steam, which opens in Big Picture for signing in.

Measured on an M4 Max (Oct 12): about 35 s from image to "Ready". Before any game the VM takes
**5.7 GB** of the Mac (the kit's way took 17 GB: a full Fedora with compilers, a second copy of
the x86 system, Lima's image cache and the 2.5 GB Vulkan SDK). The first Windows game brings
Proton and Steam's runtime (~2-2.5 GB more).

**Installing and uninstalling (Oct 21, in 0.7.0.5)**

- **Moving to Applications** (`host/Portalistic/App/AppDelegate+Install.swift`). A packaged app that
  starts outside `/Applications` and `~/Applications` (and isn't a copy built from the kit) asks
  "Move Portalistic to your Applications folder?" before it does anything else: **Move to
  Applications** or **Not Now** (this copy then starts as it is; the box "Don't ask again" stops the
  question for good, the app menu's "Move to Applications…" still does it later). When the same
  version is already in Applications the question is "Open that one instead?" (**Open That One**).
  Moving copies the app with `ditto` to a hidden `.Portalistic-copying.app` next to the destination,
  checks the copy (`codesign --verify --deep --strict`, then `spctl -a -t exec`) and only then puts
  it in place; when Gatekeeper accepts it the download's quarantine mark comes off the copy, so
  macOS doesn't ask again. The copy is made without the source's extended attributes (a folder
  that iCloud or Dropbox looks after leaves marks that fail the strict check) and the quarantine
  mark is put back before the check. A copy that doesn't pass is deleted and the app says so.
  The copy opens with `--just-installed --moved-from <old path>` (a new instance; the old one
  quits), and the new one moves the old one to the Trash (only if it's a Portalistic app with the
  same bundle ID, isn't read-only translocated and can be deleted). An older Portalistic in the
  destination is replaced (it goes to the Trash); the same version is left alone and opened; an app
  with another bundle ID called Portalistic is never touched ("Move it away, then open this copy
  again"). An app that macOS runs from a random read-only place (App Translocation, which happens
  to a quarantined app opened straight from Downloads) is found at its real place first
  (`SecTranslocateCreateOriginalPathForURL`). The app menu has "Move to Applications…" too, shown
  only when it applies. `~/Applications` counts as installed.
  **0.7.0.12 (Oct 23):** from 0.7.0.1 to 0.7.0.11 "Move to Applications" quit the app at once instead of copying:
  the question is asked before the main window exists, so the alert closing was the last window closing and
  `applicationShouldTerminateAfterLastWindowClosed` ended the app (the self-test `mac-installapp1` answers through
  an environment variable, with no alert, so it never saw it; found on the dev Mac with the real download,
  `mac-installapp8`, and the system log's "applicationShouldTerminate: NSTerminateNow" right after the answer).
  `installing` holds that rule off during the move. Each step is logged to `app-install.log` (the self-test's
  log file when set).
- **Games from before come back (0.7.0.13, Oct 23).** Michael reinstalled on the M1 without deleting the games
  and Steam showed none: Steam's first start (which installs Steam) comes before `bottle-libraries sync` can add
  the folder, and the GOG/Epic records (`stores/games.json`, Legendary's `installed.json`) went with the VM. Now
  the watcher's `libs_guard` (in the playmap block; the VM answers `libmissing TAB name` for a connected game
  folder missing from `libraryfolders.vdf`) restarts Steam once per folder per hour, with a banner;
  `bottle-stores adopt` (run by every `sync`) rebuilds a GOG record from `goggame-ID.info` (play task, Galaxy,
  size from disk) and an Epic one through `legendary import --skip-dlcs` when signed in; `cmd_setup` adds a
  drive's "Portalistic Library" folder (marker file) again. Tests: `stores-selftest.py` (adopt), `mac-playmap2`
  section 4c, `mac-libguard1/2` (the VM's answer, with the SSD taken out of a copy of the vdf).
- **Uninstall** (Portalistic > Uninstall Portalistic…, `bottle uninstall --list | --yes`). The
  dialog lists what goes: the Linux system (`~/.portalistic/lima/steamos-bottle`, or the
  `steamos-bottle` VM in `~/.lima` on a Mac set up with the kit), then settings, logs, caches and
  downloaded updates (`~/.portalistic`, `~/.config/steamos-bottle`, `~/Library/Caches/Portalistic`,
  `~/Library/Logs/Portalistic`) with their sizes. Game folders stay unless "Also move my game
  folders to the Trash" is ticked: then every game folder Portalistic made (one with the
  `.portalistic-library` mark in it, not behind a link) goes to the Trash, not deleted, so it
  can be got back until the Trash is emptied. Then the app goes to the Trash, its settings are
  forgotten and it quits. `bottle uninstall` works only inside Portalistic.app (the kit, a
  development folder, refuses), only inside the home folder, and deletes the VM through `limactl
  delete` (falling back to stopping its processes and removing the folder).
- **Tests** (all use made-up folders; nothing touches the real home folder or VM):
  `host/tests/mac-installapp1.sh` (8 cases, 19 checks: fresh copy, same version present, older
  version present, another app present, Not Now, already in Applications, just-moved, the Trash
  step's refusals; against the packaged app in test mode), `mac-installapp2.sh` (the notarized
  release's copy steps with a quarantine mark: Gatekeeper still accepts it, the mark goes),
  `mac-uninstall1.sh` (the shell command, 24 checks) and `mac-uninstallapp1.sh` (the app's
  Uninstall with a fake `limactl`, fake home and fake Trash, 13 checks). Test mode:
  `PORTALISTIC_SELFTEST=install|installed|uninstall` (no window, no VM; `uninstall` refuses unless
  `HOME` is under `/tmp`), `PORTALISTIC_APPLICATIONS_DIR`, `PORTALISTIC_TRASH_DIR`,
  `PORTALISTIC_INSTALL_ANSWER=move|later`, `PORTALISTIC_SELFTEST_LOG`, `PORTALISTIC_SELFTEST_GAMES=1`.
  Not tried: a real download in a browser (quarantine and translocation as macOS really does
  them) and how the dialogs look.

**Games stay off the Linux system's drive (Oct 21, in 0.7.0.6)**

Steam lists its own drive (the VM's 20 GB disk: Linux, Steam, Proton and its runtimes) next to the
game folders in the install window. On a new laptop a Rocket League install filled it: Steam said
it was out of space at every start, and Settings > Storage > Move sat at 0% (a game that isn't fully
installed can't be moved, and nothing could be written).

- **The guard** (`homegames_guard` in `host/bottle`, run by the watcher every round with the same
  question that asks for the VM's free space and Steam's state). The VM lists the app manifests in
  `~/.local/share/Steam/steamapps` (`homegames_cmd`: appid, StateFlags, installdir, name). Tools
  (names starting `Proton`, `Steam Linux Runtime`, `Steamworks Common`, `FEX`) belong there. Anything
  else whose StateFlags lack 4 (fully installed) is a game being installed or interrupted: Steam is
  stopped, the manifest, `downloading/<appid>`, `downloading/state_<appid>_*` and `common/<installdir>`
  are deleted (an installdir with a slash or `..` is ignored), Steam is started again, and a banner
  says why and to set Install to a game folder. A fully installed game there is left alone. Nothing
  happens while a game runs (Steam would have to quit). The same app three times in ten minutes
  (Steam keeps starting it): one banner, no more cancelling. `BOTTLE_HOME_GAMES=0` turns it off;
  `bottle _homegames-guard [STATE]` runs one round by hand.
- **The log cap** (`vm_logs_cap_cmd`, also in the tidy that `bottle disk clean` and the low-space
  guard run). Steam's web helper logs `eglGetMscRateANGLE: glXGetMscRateOML failed` (our X server has
  no GLX_OML_sync_control) about every frame into `config/htmlcache/chrome_debug.log` and
  `logs/steamwebhelper.log`: 8 GB and 3.3 GB in two weeks on the development Mac. Both only hold that
  noise, so either over 50 MB is emptied in place. `bottle disk` now lists those folders and the
  biggest folders on the whole disk.
- **Tests** (`host/tests/`, made-up folders, bash 5 and the Mac's 3.2): `mac-homegames1.sh` (20
  checks: the VM's list, a game cancelled while tools and an installed game stay, a running game, the
  off switch, odd lines, an installdir like `../outside`, the third-time rule), `mac-vmlogs1.sh` (12:
  the cap with a log held open for appending, and the watcher's exact line run locally),
  `mac-homegames2.sh` (the question through limactl into a real VM, listing only).

**Steam's interface on the Mac's GPU, by itself (Oct 21, in 0.7.0.7)**

Big Picture is a Chromium page drawn with OpenGL. Without `bottle steam-gpu on` that runs on the Linux
system's processor (llvmpipe): about 185% of a 4-CPU VM while idle on a 2020 M1 MacBook Pro with 8 GB, and
Big Picture was choppy there. By hand (`steam-gpu` set to zink) it was fine. So every Steam start now
tries the Mac's GPU first, once per kit version, and goes back by itself if it can't:

- **At a Steam start** (`steam_start` calls `gpu_auto_prepare`): with no earlier choice, the VM-side check
  (`steam_gpu_check`, 120 s: zink on the Mac GPU, a transparent OpenGL 3.3 core window drawn through GLX and
  EGL; it installs glx-utils and xwd if they're missing) must pass; then `steam-gpu` is set to zink and the state is
  `pending`. A failed check is `failed` and not tried again until the kit's version changes.
- **In the watcher, every round** (`gpu_auto_guard`, with a line from `gpu_auto_cmd`): `pending` becomes `ok` as
  soon as Steam's web helper reports a zink renderer since Steam's start (`webhelper_gpu.txt`). Its first tries
  normally fail ("failed to initialize GL thread"; 2 to 4 on the M4 Max, once 9), so it only gives up after 12
  failed tries or 5 minutes since the web helper first started: the setting is removed, the state is `failed`,
  logs are saved, Steam restarts on the processor and a banner says so. Nothing happens while a game runs.
- **Existing installs** where Steam runs on the processor with no choice made: after Steam has been up for 3
  minutes and nothing is going on, one restart, which makes the same decision. A copy set to zink by hand is
  remembered as `on`.
- **State** is one line in the VM, `~/.config/steamos-bottle/steam-gpu-auto`, `STATE VERSION`: `on`/`off` (chosen
  by hand: `bottle steam-gpu on|off` or Steam > Steam's Interface: GPU or Processor…; never changed by itself),
  `pending`, `ok`, `failed`. `BOTTLE_STEAM_GPU_AUTO=0` turns all of it off.
- **Why the old check failed on the M1 laptop (Oct 21):** `bottle steam-gpu on` gave up after 2 failed web-helper
  tries (about 20 s) and put Steam back on the processor, just before the third try would have worked. It now
  waits for 12 and up to 150 s for the window.
- **Tests (dev only, gitignored):** `host/tests/mac-gpuauto1.sh` (51 checks on Linux, 45 on the Mac's bash 3.2; the
  decision, the guard and the VM's line, on made-up folders with stand-ins), `mac-gpuauto3.sh` (the check for
  real on the development Mac's VM: passes in 8 s, settings unchanged), and the watcher on the development Mac
  took the new code up by itself and wrote `on 0.7.0.6` from a real round.
- **Not verified yet:** a fresh install end to end (the first start trying the GPU); the fall-back path with a Mac
  where the web helper really never works; the restart of an existing install; the menu item's look.

**Games installed while Steam runs, and a game's first start (Oct 21, in 0.7.0.7)**

Steam reads which Steam Play tool a game uses only when it starts, and `bottle-steamplay map` (run by
`steam-arm64` before every start) is what sets each installed game to Proton Experimental. A game installed
while Steam was already running therefore came as its **Linux version** if it has one (Dead Cells, Rocket
League...): an x86-64 Linux program in an arm64 VM, so **Play did nothing** (the button flipped to Stop and
back) until Steam was restarted; then Steam swapped the depots (Dead Cells: about 2 GB again) and it ran.
Found Oct 21 on a 2020 M1 MacBook Pro and confirmed on the development Mac.

- **`bottle-steamplay pending [--mark]`** (Steam running; prints nothing otherwise): one line `pending TAB appid TAB
  name` per installed app that is not a tool, has a **Linux version**, is not mapped to Proton in `config.vdf`, is
  not in `native-apps`, is not one the player set himself in Steam (`steamplay-choices.json`, or a setting that
  changed since `steamplay-set.json`) and was not listed in the last 30 minutes. The Linux version comes from
  Steam's own cache, `appcache/appinfo.vdf` (binary VDF, version 41; `common/oslist`: Dead Cells "windows,macos,linux",
  ASUKA demo "windows"); the app manifests can't say it, they carry no `platform_override_*` on this Steam, for
  Windows or Linux installs alike. A game for Windows only is left alone (Steam Play is its default); one missing
  from the cache, or a cache in another version, can't be told and is listed. A manifest is listed from its second
  sighting, 6 s after the first (`playmap-seen`). `--mark` notes the games as tried (`playmap-tried`). Takes
  about 50 ms, 2 ms of it reading the cache.
- **In the watcher, every round** (`playmap_guard`, lines from `playmap_cmd`): with no game running, Steam up for
  30 s and a `pending` line, the guard asks again in the VM with `--mark` (and only when nothing is running there),
  then `steam_stop` and `steam_start`; `map` runs in between, so the game comes back as its Windows version, and a
  banner says why ("Steam restarted for Dead Cells ... It may download the game again."). While a game waits, the
  watcher looks every 8 s instead of every 60 s (at most 15 rounds in a row). At most three restarts an hour;
  `BOTTLE_PLAYMAP=0` turns it off. `bottle _playmap-guard [STATE]` runs one round.
- **First start of a Windows game:** Proton builds the game's Wine prefix (`compatdata/APPID/pfx`) the first time,
  and shows nothing: about 9 minutes on the M1 laptop, with the game's Play button turning into Stop and the log
  holding only its header. A launch (`reaper SteamLaunch AppId=N`, seen by the watcher) whose
  `pfx/creation_sync_guard` is missing after 15 s gets a banner, once per launch: "Setting up <game> for the first
  time. Windows games need a one-time setup before they open. It can take several minutes, and the game starts by
  itself when it's done." `BOTTLE_PREFIX_NOTICE=0` turns it off.
- **Tests (dev only):** `guest/tests/steamplay-pending-selftest.py` (26 checks on a made-up Steam folder, home and
  appinfo.vdf; runs in the container and in the VM), `host/tests/mac-playmap2.sh` (47 checks on Linux, 37 on the
  Mac's bash 3.2, which skips the checks that need Linux processes: the guard's decisions with stand-ins, the VM's
  lines from stand-in processes, the whole round script read by bash, the wiring), `mac-playmap4.sh` (the round
  through limactl on the dev VM), `mac-playmap5.sh`/`mac-playmap6.sh` (the manifests and the cache as they are
  there), `mac-playmap7.sh` (the kit's `bottle-steamplay` against the dev VM's real cache: oslist read for four
  games in 2 ms, nothing pending on a VM whose games are all set). Not verified yet: a real install on a real VM
  (that `creation_sync_guard` is missing for the whole prefix build, and that Steam has a just-installed game in
  its cache on disk).

**Proton's prefixes on the VM's disk, and a banner for Steam's install step (Oct 22, in 0.7.0.8)**

On the 2020 M1 MacBook Pro (macOS 26.3.1, 8 GB) the Mac game folder's share (virtio-fs in libkrun 1.19.6 / krunkit
1.3.2) sometimes never answers a request: the guest process waits in `request_wait_answer` forever while krunkit's
fs workers sit idle (a `sample` of krunkit showed both in `kevent`), and the same file answers the next time. Seen
on Proton's `chmod` while starting Dead Cells, on `stat` by the watcher's `find` in `steamapps/downloading`, and on
`proton run` (Steam's install step for Devil May Cry 5's DirectX/VC++ installers). Not reproduced on the M4 Max
(macOS 26.6.2). The heaviest traffic on that share was Proton's prefixes (thousands of small files; a first start
took 9 minutes there), so:

- **`bottle-libraries sync`** (before every Steam start): for each shared game folder, `~/.local/share/steamos-bottle/
  compatdata/NAME` is bind-mounted (`sudo -n mount --bind`) over `/mnt/portalistic/NAME/steamapps/compatdata`.
  Prefixes already in the folder are copied first (`cp -a`, 5 minutes at most each, through a staging folder; the
  space needed plus 2 GB must be free on the VM's disk, else nothing changes). A copy that doesn't finish: no mount
  this time; the second time that game is set up anew (its old prefix stays in the Mac folder, hidden under the
  mount; `prefix-copy-failed.json`). The originals are never deleted. `BOTTLE_LOCAL_PREFIXES=0` turns it off.
  Dev Mac, Oct 22 13:47: four prefixes, 1.6 GB, copied in seconds; on btrfs with zstd they took about 0.2 GB.
- **Steam's install step:** a launch with `Install=1` or `proton run` in the reaper's command line is `install` in
  the watcher's lines (`launch ... play|install NAME`); after 20 s a banner says "Finishing the install of NAME".
- Tests: `guest/tests/libraries-prefixes-selftest.py` (20 checks: copy, mount, a failed mount takes this run's
  copies back, a stuck copy twice, the off switch, a folder not connected), `host/tests/mac-playmap2.sh` (54 checks
  on Linux, 43 on the Mac's bash 3.2), `mac-prefixes1..3.sh` (the dev VM before and after).
- Still open: why libkrun's share loses those requests (libkrun main has an eventfd fix for macOS, 137f84b, that
  isn't in 1.19.6; whether it's related is not known). Game files themselves are still read through the share.

**A "please wait" window while Steam gets ready (Oct 22, kit)**

On the laptop, after updating to 0.7.0.8 and restarting Steam, the window stayed black for about 10 minutes before
Steam's start animation. `guest/bottle-splash` now shows zenity's progress window (zenity is in the Linux image) on
the bottle's screen: `show TEXT` (appears only after 3 s), `text TEXT`, `until-steam` (closes 2 s after a Steam
window is mapped: `wmctrl -lx`, at most 10 minutes), `close`; at most 15 minutes in any case. `update_if_behind`
shows it when Steam starts next (from the kit's copy, so the first update to this version has it too); each step
of `update-guest.sh` writes its name to it and now prints its time; `steam-arm64` shows it at its start, names
each part (game folders, other stores, Steam Play, DXVK) and logs their times in `steam-timing.log`.
- **0.7.0.11:** the zenity window never showed on the laptop (the VM's desktop wasn't up yet), so the card is the
  Mac app's own: `bottle-splash` writes `~/.cache/steamos-bottle/notices/splash.txt` as a notice of kind 2
  (`2 600\nTEXT`; `-` takes it down), `bottle-screen` passes the kind through, and the app's `ProgressCard`
  (NoticeView.swift) shows it centered until the next kind-2 notice. `show|text` starts one watcher (`splash.pid`)
  that closes the card 2 s after a Steam window is mapped, or after 15 minutes. The Activity window
  (`ActivityWindow.swift`) shows the bottle command's `==>` lines as steps with a spinner/tick, the latest plain
  line under the current step, and the raw output behind Details (opened on failure). The Bottle menu is the
  **Steam** menu (Start the VM, Update the VM). Dev Mac, Oct 22 21:51: Restart Steam showed "Starting Steam…" from
  21:47:26 until Steam's window at 21:47:40.
`BOTTLE_SPLASH=0` turns it off. The x86 Vulkan probes in `install-x86.sh` run only when the layers or the x86
Venus driver changed (`/var/lib/steamos-bottle/x86-probe-stamp`; `BOTTLE_FORCE_PROBE=1`). The prefix copy now
waits at most 20 s for the listing, 60 s for the size, 120 s per prefix and 240 s in all. Dev Mac, Oct 22 16:10:
update 14 s, Steam's own steps 2 s, the window showed "Starting Steam…" and went with Big Picture.

**A game folder is a drive (Oct 22, kit; 0.7.0.9)**

The lost requests on the laptop's virtio-fs share (above) hit anything on the game path: Proton's chmod at a game's
start, Steam's install step reading the game's installers (DMC5 sat "finishing" for 20 minutes), the watcher's
find. Moving the prefixes (0.7.0.8) wasn't enough. The VM's own 20 GB drive, a plain file through virtio-blk,
never hung on either Mac, so games now live on drives too:

- **Mac side** (`lib_disk_prepare`, from `lib_mounts_expr` at every VM start): each game folder gets
  `Portalistic Games.img`, a sparse raw file as big as the volume it's on (`df -k`; 1 TB when unknown), starting
  with the header `PORTALISTIC-GAMES NAME`; `~/.lima/_disks/pg-NAME/datadisk` is a symlink to it and
  `additionalDisks: [{name: pg-NAME, format: false}]` goes to Lima next to the mounts. The folder itself is still
  shared, now at `/mnt/portalistic-folders/NAME`. `libraries.json` carries `"disk": true` and the Mac's `"free"`
  bytes per folder. A failed start leaves Lima's `in_use_by` note on the disk; it's removed when the VM isn't
  running. `bottle library remove` forgets the Lima disk (`lib_disk_forget`); the image stays in the folder.
  `BOTTLE_GAME_DISKS=0`: the plain share, as before.
- **krunkit patched** (`host/krunkit/`): Lima names every additional disk's file `datadisk`, krunkit uses the file
  name as the block id, and libkrun keeps one MMIO device per id, so only the last disk reached the VM. The patch
  (`krunkit-datadisk-id.patch`, 15 lines) makes the id `pg-NAME-datadisk`. `build.sh` builds it on the development
  Mac (Homebrew's rust, installed if missing; libkrun from Homebrew; firmware linked at `host/share/krunkit`);
  `package-app.sh` takes it when it's newer than the patch, else Homebrew's with a warning. The kit's `bottle`
  puts `host/krunkit` first on PATH. The binary and `host/share` are gitignored.
- **VM side** (`bottle-libraries sync`, before Steam starts): the disk is found by its label `portalistic-NAME`
  or, unformatted, by the header (`sudo dd`), formatted once (`mkfs.btrfs -L`), mounted at `/mnt/portalistic/NAME`
  (`noatime,discard=async`; `btrfs rescue fix-device-size` first when the mount fails: Lima trims the image by
  4 KB at the first start, which btrfs refuses), and sized to what's in it plus the Mac's free space minus 2 GB
  (`btrfs filesystem resize`), so Steam can't start a download the Mac can't hold; `tidy` (the watcher, every 10
  minutes while no game runs) does `fstrim` and the resize again. Games in the folder itself move into the drive
  once: per game `rsync -a --partial` (an hour at most, three tries; a lost request ends a try), its
  compatdata/shadercache, then the manifest; the folder's copy is deleted once the game is in. Prefixes 0.7.0.8
  had copied to the VM's disk go back into the drive. Dev Mac, Oct 22 17:21: Dead Cells moved in a minute, the
  SSD's 156 GB at about 150 MB/s; `fstrim` after deleting 2 GB took the Mac file from 2 GB to 356 KB.
- **0.7.0.10:** `GOG Games`/`Epic Games` (bottle-stores' folders next to steamapps) move too, one game folder at a
  time (`NAME.moving` until done). The folder's copies are no longer deleted through the share: the VM appends
  `APPID<TAB>DIR` to `steamapps/.moved-into-drive` and `STORE<TAB>GAME` to the folder's `.moved-into-drive`, and the
  Mac's `lib_moved_cleanup` (at `vm_start`, in `lib_disks_tidy` every 10 minutes, `bottle _lib-cleanup`) deletes
  them. `cmd_up` starts the desktop before the update so the splash can show. Dev Mac, Oct 22 20:00: Blades of
  Time, GWENT, Prey (GOG) and BioShock Remastered (Epic) moved (one `rm` through the share had hung on the laptop
  for minutes); Blades of Time and BioShock started from the drive.
- Tests: `guest/tests/libraries-disks-selftest.py` (17 checks: mount stand-in, the move, contentid kept, no bind
  mount for a drive, prefixes back, the plain share, tidy), `host/tests/mac-disks1..20.sh` (the steps on the dev Mac).

**Making a release** (on the development Mac, which has the kit's setup: Homebrew's lima and
krunkit, KosmicKrisp, Xcode, a Developer ID certificate):

| Step | Does |
|---|---|
| `bottle prebuild` | Builds the VM's own C programs (screen server, present layer, kopper shim, NVML stand-in, gltest) in the VM, into `guest/prebuilt/aarch64` with a MANIFEST of the sources they came from. VMs install these instead of compiling (`guest/build-recipes.sh`), so they need no compilers; they still compile when a source changed and the build tools are there (development). |
| `host/build-image.sh` | Builds the Linux image (20-40 min): a Fedora VM from Lima's template set up by `guest/setup-guest.sh` with the ready-made builds, then `guest/image-seal.sh` (no build tools, no compressed copy of the x86 system, no docs, caches, logs, user, machine ID or SSH keys) powers it off; the running bottle VM packs its disk with `qemu-img` as a compressed qcow2. Writes `build/image/` (the image, its SHA-256, 1900 MB parts for GitHub, the packages list) and `host/image.env`. `--pack` packs an already sealed image VM, `--keep` keeps it to look inside. |
| `host/package-app.sh [--notarize PROFILE]` | Builds the app and puts it together in `~/Library/Caches/Portalistic/package` (not in Documents: iCloud's extended attributes break code signatures): the app, the kit (`host/bottle`, `host/image.env`, `guest/` without tests), Lima, krunkit (Homebrew paths rewritten to `@rpath`), its EFI firmware, the libraries and KosmicKrisp. Signs everything with the Developer ID and hardened runtime (krunkit with the hypervisor entitlement), refuses ready-made builds older than their sources, zips it, and with `--notarize` has Apple notarize and staple it. Copies the result to `build/`. |

Inside the app, `host/bottle` runs from `Contents/Resources/kit` and notices it (app mode): logs go
to `~/Library/Logs/Portalistic`, Lima keeps its VMs in `~/.portalistic/lima` (or `~/.lima` if the
VM is already there, as on a Mac set up with the kit), and nothing is built at run time. Notes for
whoever packages it: krunkit looks for its EFI firmware at `../share/krunkit/` from its own folder
(else "can't find a firmware to load"); libkrun opens `libkrunfw.5.dylib` by bare name, which dyld
finds through krunkit's rpath; Lima finds its guest agent at `../share/lima/` from `limactl`
(`Contents/Helpers/share` links to `Contents/Resources/share`, since code folders may hold only
signed programs).

Third-party software and licenses: [LICENSES.md](../LICENSES.md).

## Quick start

Needs an Apple Silicon Mac, Homebrew, and macOS 26+ for Windows games (KosmicKrisp).

```bash
mkdir -p ~/Documents/Projects && cd ~/Documents/Projects
unzip -q ~/Downloads/PORTALISTIC.zip                 # the kit: ~/Documents/Projects/PORTALISTIC
~/Documents/Projects/PORTALISTIC/host/setup-host.sh  # 15–30 min the first time
bottle start                                         # desktop + Steam in Screen Sharing
```

`setup-host.sh` installs Lima + krunkit, creates and provisions the VM, installs the
`bottle` command, and offers to set up KosmicKrisp. The VM gets your performance-core
count, half your RAM and 100 GiB of disk (`CPUS=8 MEMORY=12 DISK=150 ./host/setup-host.sh`).

In Steam, a Windows game needs Properties → Compatibility → force **Proton Experimental**
the first time (games with a Linux version default to it).

## Daily use: the `bottle` command

| Command | Does |
|---|---|
| `bottle start` | Starts the VM (with KosmicKrisp), desktop, Steam and the sound, then opens Portalistic.app (same as `bottle window`; opening the app from the Dock does it too) |
| `bottle start --debug` | Same, plus a game log (`bottle log`), an FPS counter in games, and frame-rate lines |
| `bottle stop` | Quits Steam and any game, shuts the VM down |
| `bottle restart` | Stop + start (e.g. after `bottle kosmickrisp enable`) |
| `bottle steam [--debug]` | Restarts Steam only |
| `bottle vnc` | Opens the desktop over VNC instead of the app |
| `bottle status` | VM, GPU driver, desktop, Steam, running game, DXVK state of every Windows game |
| `bottle log` / `bottle log steam` | Summary of the newest game log / Steam's own output |
| `bottle log list` / `bottle log prev [N]` | Earlier game launches: Proton starts its log over on every launch, so `bottle-logkeep` (runs with Steam) keeps the last 8 per game; `prev` summarizes the last one, e.g. a launch that crashed |
| `bottle perf` | While a game runs: Mac CPU/GPU load (also per VM thread), the VM's busiest processes, busiest game threads, the game's frame pacing (hitches, shader compiling), and (with `--debug`) the game's swapchains, how each frame's time splits into GPU, screen and game, and what the game asks per frame (draws, submits, new pipelines). The keep-awake loop writes the same every 30 s of play to the kit's `logs/game-perf.log` |
| `bottle fps [N\|off]` | Cap games at N fps (DXVK's limiter, `DXVK_FRAME_RATE` in steam.env; restarts Steam). A game that keeps the Mac's GPU flat out heats a MacBook until macOS slows it down; a cap a little under the game's early frame rate keeps it steady. One game only: `DXVK_FRAME_RATE=45 %command%` in its launch options |
| `bottle memory [GB]` | The VM's memory (restarts the VM); no argument: how much it has and what's suggested (half the Mac's under 24 GB, 4-8 GB; a third from 24 GB, 8-16 GB). The VM's file cache and the games' GPU memory both live in the Mac's memory |
| `bottle tso [on\|off]` | x86 memory ordering in hardware (Apple's TSO mode, as Rosetta uses): tests that it works in the VM, measures what it's worth, keeps it on if it holds; FEX then stops ordering every memory access of x86 games in software. Restarts Steam. No argument: whether it's on |
| `bottle gputrace` | While a game runs: records 3 s of the Mac GPU timeline with Instruments (needs Xcode) and packs the tables into `~/Desktop/bottle-gputrace-*.zip` for analysis |
| `bottle window` | Open **Portalistic.app** (built once into ~/Applications): the VM's screen in a Mac window with keyboard, mouse and sound. When a game hides its pointer (mouse-look) the mouse is captured and sent as raw motion; ⌘Esc releases it, a click captures again; ⌃⌘F full screen |
| `bottle audio [on\|off]` | The bottle's sound on the Mac (on by default with `bottle start`) |
| `bottle env KEY=VALUE` | Set a setting for Steam and its games (e.g. `DXVK_CONFIG`, `BOTTLE_PRESENT_SWAP_RB=1`); `bottle env` lists them, `bottle env -u KEY` removes one. Applies from the next `bottle steam` |
| `bottle env --mac KEY=VALUE` | The same for the VM process on the Mac (KosmicKrisp settings). Applies from the next `bottle restart`. The kit sets `MESA_KK_DISABLE_WORKAROUNDS=6,12,13,14,17` by default (see below); `bottle env --mac MESA_KK_DISABLE_WORKAROUNDS=` restores KosmicKrisp's own defaults |
| `bottle xcode` | Opens the app's Xcode project and sets your signing team; from then on the app is built with Xcode, signed with your team |
| `bottle steam-gpu [on\|off]` | Steam's interface (Big Picture) on the Mac's GPU through zink, after checking it works; off goes back |
| `bottle ui [bigpicture\|desktop]` | Steam's interface in the bottle: Big Picture (default, as on SteamOS) or its desktop windows |
| `bottle mode [game\|desktop\|install\|status]` | Game Mode (Steam's Big Picture fills the screen; the default) or Desktop Mode (KDE Plasma, as on a Steam Deck; the first switch to it downloads about 550 MB); no argument: which one |
| `bottle library` / `bottle play APP_ID` | The installed games (app id, name, state, last played) / start one |
| `bottle library folders` | Where games go: each game folder, the VM's disk, the free space on each, how many games each has, and the default for new games |
| `bottle library add PATH [--default]` | A new place for games: a folder on this Mac (`~/Games/Portalistic`) or a drive (`/Volumes/SSD`: Portalistic makes a "Portalistic Library" folder on it). Restarts the VM. Also in the app: Game Folders > Add a Game Folder… (see "Where games go" below) |
| `bottle library default NAME` | Where new games install (a name from `bottle library folders`, or `vm` for the VM's disk); restarts Steam. Steam's own Settings > Storage > Make Default works too |
| `bottle library remove NAME` | Stop using a game folder; its games stay in it, and `bottle library add` brings them back. Restarts the VM |
| `bottle disk` | What fills the VM's disk, how much of the Mac it takes, and the Mac's free space |
| `bottle version GAME linux\|windows` | Run a game (app ID, part of its name or its initials: `cs2`, `w3`) as its Linux version (Counter-Strike 2: Valve's anti-cheat only accepts that one here) or as its Windows version through Proton (the default); restarts Steam, which downloads that version. No arguments: every game's. Steam's own setting (Properties > Compatibility, "Force the use of a specific Steam Play compatibility tool") works as well and now sticks |
| `bottle gog login ADDRESS` / `bottle gog logout` | Sign in to GOG (`bottle gog login-url` prints where; ADDRESS is the page the browser ends on, or just its code) / forget the sign-in. Also in the app: Stores > GOG Games… (see "GOG games" below) |
| `bottle gog list` / `bottle gog folders` | The games your GOG account owns that have a Windows version / the game folders they can go to |
| `bottle gog install ID [--folder NAME]` | Downloads a GOG game into a game folder (`GOG Games` inside it) and adds it to Steam as a non-Steam game that runs through Proton; restarts Steam to show it. Running it again updates the game |
| `bottle gog remove ID [--purge]` | Deletes the game and its Steam entry (`--purge`: also its Wine prefix, which holds saves and settings); restarts Steam |
| `bottle epic login TEXT` / `bottle epic logout` | Sign in to Epic Games (`bottle epic login-url` prints where; TEXT is what Epic's page shows after signing in, or just its `authorizationCode`) / forget the sign-in. Also in the app: Stores > Epic Games… (see "Epic games" below) |
| `bottle epic list` / `bottle epic folders` | The games your Epic account owns that have a Windows version Legendary can install / the game folders they can go to |
| `bottle epic install ID [--folder NAME]` | Downloads an Epic game (ID: the name `list` shows) into a game folder (`Epic Games` inside it) and adds it to Steam as a non-Steam game that runs through Proton; restarts Steam to show it. Running it again updates the game |
| `bottle epic remove ID [--purge]` | Deletes the game and its Steam entry (`--purge`: also its Wine prefix); restarts Steam |
| `bottle update` | Copies this kit into the VM and brings it up to date (after unzipping a newer kit) |
| `bottle setup [IMAGE]` | First launch on a Mac without the VM: downloads Portalistic's Linux image (`host/image.env`), makes the VM, starts it, installs Steam (the app runs it); IMAGE: a local image file |
| `bottle prebuild [PROGRAM...]` | Builds the VM's own programs in the VM into `guest/prebuilt/aarch64` (see "Portalistic.app" above); with names, only those |
| `bottle shell` | A shell inside the VM |

**Windows Steam on the Mac itself was tried and dropped (Oct 11-12).** A second bottle ran the
Windows version of Steam with Wine directly on macOS (Rosetta 2, DXVK-macOS, MoltenVK). Steam,
its store and DirectX 11 games worked, but there is no open DirectX 12 for macOS: MoltenVK lacks
geometry shaders and more, so Wine's vkd3d stays below feature level 11_0, and Apple's D3DMetal
is licensed only for developing and evaluating games. DirectX 12 games run in the VM instead, so
the Windows bottle was removed from the kit.

Permanent settings for Steam and games live in `~/.config/steamos-bottle/steam.env` inside
the VM (`PROTON_LOG=1`, `DXVK_HUD=fps`, `BOTTLE_PRESENT_DEBUG=1`, `BOTTLE_DXVK=0`).

**Updating to a newer kit:** unzip it over `~/Documents/Projects/PORTALISTIC`, then `bottle update`
and `bottle steam`.

### GOG games (Oct 14)

Steam in the bottle can't run GOG's own launcher, so Portalistic does what Heroic does. **Stores >
GOG Games…** (or `bottle gog …`) signs in to GOG, lists the games you own that have a Windows
version, and installs one: the VM downloads it with `gogdl` (Heroic's GOG downloader, in
`guest/stores`) into a game folder (the one you chose as default, or another from the menu next to
the Install button; a drive works, with the usual space check), under `GOG Games`. Then Steam
restarts (unless a game is running) and the game is in its library as a **non-Steam game** in the
collection "GOG", in Big Picture too, running through Proton Experimental like every Steam game,
with DXVK 2.6.2 and vkd3d-proton 3.0.1 from the bottle.

- **The list (both stores' windows)** shows the installed games first, in colour with an "Installed" badge;
  the others follow in black and white. The menu next to All / Installed orders each group: name A to Z,
  Z to A, or by year, newest or oldest first (games without a year go last); each store remembers its
  choice. The year is the release year the store gives: GOG's release date, and for Epic the PC release date
  of the game's offers in Epic's public store (asked once per game, without signing in, and kept in
  `epic-years.json` in the stores folder; if the store can't be reached the list comes without years and
  asks again an hour later). The bar under the grid says "Released YEAR" for a chosen game.
- **Under the mouse** a cover pops: it swells about 7 % (rising, so it stays clear of its title) with a small
  overshoot, lifts on a shadow above its neighbours, and eases back when the mouse leaves. With "Reduce
  motion" on in System Settings it changes size at once instead. Only these two windows do this.
- **Signing in** opens GOG's own page in your browser. The browser ends on an almost empty page;
  you copy its address (it contains `code=`) and paste it in the window. Portalistic never sees
  your password; the sign-in GOG hands back is kept in the VM (`~/.config/steamos-bottle/stores`,
  readable only by you) and removed by Sign Out.
- **How it's wired** (`guest/bottle-stores`): each installed game is a record in
  `stores/games.json` (its folder, program, arguments, a Steam app ID); `bottle-stores sync` writes
  those into every Steam user's `shortcuts.vdf` (the binary file for non-Steam games) while Steam
  is stopped, and leaves the player's other shortcuts and everything Steam stored in ours (last
  played...) alone. The app ID is Steam's own for a shortcut (a CRC of the quoted program path and
  name, top bit set), which names the Proton setting `bottle-steamplay` writes and the artwork.
  `steam-arm64` runs the sync before Steam starts, so a change shows after a Steam restart.
- **Artwork** (Oct 14): Steam's library shows a non-Steam game only by the pictures in its grid folder
  (`userdata/ID/config/grid`, named by the app ID), so without them a game is a blue tile with its
  name. An install fetches four pictures from GOG's public game page (`api.gog.com/v2/games/ID`, no
  sign-in): the tall cover (`IDp.jpg`, what the library's tiles and the home row show), the Galaxy
  background (`ID_hero.jpg`, the banner of the game's page, and `ID.jpg`, the wide tile), the title
  logo (`ID_logo.png`) and the icon. A game installed earlier gets them at the next Steam start (one
  try an hour while GOG can't be reached). A picture the player set in Steam stays; ours are
  replaced when GOG's change. Nothing from GOG is stored in this kit.
- **Updating a game**: choose it and click Update (it downloads only what changed). **Removing**
  deletes its files, its gogdl record and its Steam entry; its Wine prefix (saves, settings) stays
  unless you tick the box.
- **32-bit games** (Blades of Time is one) run on Wine's 32-bit side, which needs its own copy of the
  Mac-patched GPU driver and of the bottle's Vulkan layer in the x86 system (`x86-venus.sh` and
  `install-x86.sh` put both there; "32-bit games" under the Oct 14 GPU update below). Without them such
  a game dies on its first buffer or sits on a white window. Steam games are no different.
- **The Galaxy sign-in** (Gwent is one): a game with GOG's Galaxy SDK in its folder (`Galaxy.dll`
  or `Galaxy64.dll`) asks the Galaxy client's background service for your sign-in, achievements and
  leaderboards, and without it says "User is not signed in. To continue, start the GOG Galaxy
  client". The VM can't run that client, so the kit carries **Comet**
  (https://github.com/imLinguin/comet, Apache-2.0), the open-source stand-in Heroic uses, as a
  ready-made arm64 build in `guest/comet` (pinned to its v0.3.2 commit; `build-aarch64.sh` rebuilds it
  in the development VM; `update-guest.sh` installs it to `/usr/local/share/steamos-bottle/comet`;
  `package-app.sh` refuses to package without it and its license notices). For such a game
  `bottle-stores sync` sets the Steam shortcut's launch options to
  `/usr/local/bin/bottle-stores run -- %command%` (other games keep plain options). `run` signs
  Comet in with the GOG sign-in Portalistic already holds, through a private link where Comet looks
  for Heroic's file (`stores/comet-cfg`; no token on a command line), starts it on port 9977 unless it
  already runs, waits on the first use while Comet fetches GOG's Galaxy files (about 27 MB, kept in
  `~/.local/share/comet`; GOG's, downloaded from GOG, not shipped), runs the game, and stops the Comet
  it started when the game ends (Comet's log: `~/.cache/steamos-bottle/comet.log`). If Comet or the
  sign-in is missing, the game starts anyway. Like the Galaxy client, Comet reports the game's
  achievements and statistics to your GOG account. It doesn't offer GOG's overlay or friends list.
- **Not done yet**: games' own redistributable installers (`__redist`: Visual C++, DirectX) aren't
  run, which some games need; DLC and extras aren't downloaded; GOG cloud saves aren't synced;
  games run as their Windows build only. gogdl's patch module (`gogdl_xdelta3`) is built with the
  VM's other programs (`bottle prebuild gogdl_xdelta3.abi3.so`); without it a fresh install works,
  and only an update that GOG ships as patches doesn't.

### Epic games (Oct 14)

The same way, for the Epic Games Store: **Stores > Epic Games…** (or `bottle epic …`) signs in to Epic,
lists the games you own that have a Windows version, and installs one with **Legendary**
(https://github.com/legendary-gl/legendary, GPL-3.0-or-later; version 0.21.1 is in `guest/stores/legendary`,
its notice in `guest/stores/LICENSE-legendary`, the one change in `guest/stores/MODIFICATIONS.txt`) into a
game folder, under `Epic Games`. Steam then lists it in the collection "Epic Games", running through
Proton Experimental like the rest. Pictures come the same way as GOG's, from the catalog entry Legendary
saves for the game (Epic's CDN; nothing is stored in this kit).

- **Signing in** opens Epic's own page in your browser. After you sign in, Epic shows a short line of text
  with `"authorizationCode"` in it; you copy all of it and paste it in the window (or paste just the code).
  Portalistic never sees your password; Legendary's sign-in (`~/.config/steamos-bottle/stores/legendary/user.json`,
  readable only by you) is removed by Sign Out. A sign-in lasts as long as you use it; if it runs out you sign in again.
- **Starting a game**: an Epic game wants a sign-in token on its command line (`-AUTH_PASSWORD=...`), which
  works once and for a few minutes. So the shortcut's launch options are
  `/usr/local/bin/bottle-stores run --epic NAME -- %command%`: `run` asks Legendary for the game's arguments
  (it signs in with the saved login and gets a fresh token) and starts the game with them. If that doesn't
  work (no network, an expired sign-in) the game still starts, without the sign-in, and says why in
  `~/.cache/steamos-bottle/epic.log`. The token is never written to a log; it can be seen in the game's
  command line while it runs, which is how Epic's own launcher passes it too.
- **How it's wired**: `guest/bottle-stores` runs Legendary as a program (`python3 -c` with the
  `multiprocessing` start method set to `fork`, because Python 3.14's default doesn't suit Legendary's
  downloader), its files in `stores/legendary`, the games in `stores/games.json` under `"epic"`, installed
  with `update-guest.sh` into `/usr/local/share/steamos-bottle/legendary` (with `python3-filelock` and
  `python3-pycryptodomex` from Fedora). Legendary asks `api.legendary.gl` for the launcher version to
  present to Epic, once a day, as it always does.
- **Updating a game**: the window says when Epic has a newer version; Update downloads only what changed.
  **Removing** deletes its files, Legendary's record and its Steam entry.
- **Not done**: DLC isn't downloaded, cloud saves aren't synced, prerequisites (Visual C++...) aren't
  installed, and anti-cheat is left alone: a game that needs Easy Anti-Cheat or BattlEye to be set up by
  Epic's launcher may not start, and Portalistic does nothing to get around that. Games Epic hands on to EA
  or Ubisoft aren't listed. Downloads run one at a time (Legendary keeps a single lock on its list).

Self-test (no network, no Steam): `python3 guest/tests/stores-selftest.py`.

### Desktop Mode (Oct 14)

The bottle has two modes, as a Steam Deck does. **Game Mode** is what it always was: Steam's Big
Picture fills the screen. **Desktop Mode** is KDE Plasma (Fedora's packages, its X11 session) with
Dolphin, Konsole, Kate, Firefox, Spectacle, the System Monitor and Discover (for Flatpak apps); Steam keeps running, in a window
(it opens over the desktop; minimize it to see the desktop). Steam > Switch to Desktop Mode (or
`bottle mode desktop`) switches; the "Return to Game Mode" icon on the desktop, or Steam > Switch to
Game Mode (`bottle mode game`), switches back.

- **Installed on first use, not shipped**: the first switch downloads about 550 MB with dnf (about
  1.3 GB on the VM's disk; it wants 2 GB free) and sets Plasma up. Plasma takes about 800 MB of the
  VM's memory while it's on. `bottle update` keeps its settings in step with the kit when it's there.
- **Discover and Dolphin:** Discover installs Flatpak apps from Flathub for this user (no password; its
  PackageKit part isn't installed, so it can't offer to update the system packages, such as the Mac-patched
  Mesa). Dolphin's sidebar lists what the Mac shares with the VM: the game folders (`/mnt/portalistic/…`),
  and for a VM set up with other Lima mounts those too, marked read-only when they are. Nothing else of the
  Mac is visible to the VM, on purpose: Steam, games and Proton run there and could read or change it.
- **Icons:** the desktop's "Steam" launcher and the taskbar's Steam entry use Steam's own icon; "Return to
  Game Mode" and the Start button (Plasma's Application Launcher, which shows the distribution's logo by
  default) use the round SteamOS mark. They're cut, each time Plasma's settings are applied, from picture
  files in Steam's own folder (`public/steam_tray.ico`, `steamui/images/startup_steamos.png`) and kept in
  `~/.local/share/steamos-bottle/icons`. No Valve artwork is in this kit; before Steam has installed those
  files the launchers get a plain game icon from the theme and the Start button keeps Plasma's.
  The Start button is set through Plasma's scripting interface (`bottle-session look`).
- **How it works** (`guest/bottle-session`): `on` stops the window keeper, closes Big Picture
  (`steam://close/bigpicture`), takes openbox/xfwm4 off the screen and starts `startplasma-x11` on its
  own D-Bus (`dbus-run-session`, so leaving it leaves nothing behind). `off` logs Plasma out the normal
  way (apps close, about 5 s), clears whatever is left of the session (never Steam, Wine or a game,
  which can be started from the desktop), starts Game Mode's window manager and keeper again and
  reopens Big Picture. The mode is `~/.config/steamos-bottle/session`; `bottle-desktop`
  (`start-desktop`), `steam-arm64` and the window keeper read it, so a Steam restart or a re-run
  desktop keeps the mode; a fresh screen (the VM just started) is Game Mode. Refused while a game runs.
- **Plasma's settings here** (`bottle-session configure`): no desktop effects (every frame would cost
  the VM's processors), no lock screen or sleep (nothing in the stream could unlock it), no file
  indexing, no windows reopened from last time, and the "Return to Game Mode" and "Steam" icons.
- **Tried** on a private second screen (`host/tests/mac-desktopmode1.sh`: on, start-desktop leaves
  Plasma alone, off, a Steam-like process spared, the real screen untouched) and then once on the
  real one (`mac-desktopmode3.sh`, with pictures). Plasma draws on the VM's processors like Big
  Picture does; games started from the desktop run as always.
- **Not done**: no volume control in the panel, no clipboard between the Mac and the VM (that's the
  stream's, not Plasma's), nothing for Plasma 6.8 (it drops X11; Fedora 44 ships 6.7).

### The window, notices and the Mac's GPU numbers (Oct 11)

- **The VM's screen follows the window** (View > Screen Size). *Like the Window* (the default)
  gives the VM's screen the window's shape with as many pixels as 1080p (never more than the
  window shows): no black bars in full screen on a 16:10 MacBook display, and it follows when
  the window is resized. *Like the Window, Sharper* gives it up to 2560x1600's worth (more detail;
  more work for the VM and the Mac). *Fixed 1920 × 1080* is the old behaviour. The screen server
  (`bottle-screen`, protocol version 2) does it with `bottle-resolution` (xrandr) while no game
  runs; when a game starts the screen switches to 1920x1080 first (*Games at 1920 × 1080*, on by
  default: what the games here were tested with), and back when it ends; never mid-game. Big
  frames are JPEG-encoded in 4 bands at once, so bigger screens cost little time.
- **Why a game closed at launch.** When a launch ends within 90 s without showing a picture (the
  layer logs "first frame on screen"), or crashes, `bottle-whyquit` reads its log and the window
  shows the reason in plain words: anti-cheat, a DirectX 12 start that didn't get as far as a
  picture, Direct3D 11 features, the Mac's GPU driver stopping (device lost), a missing Windows
  library, .NET, a crash, the x86 translator, memory. For an Unreal Engine (`-dx11`) or Unity
  (`-force-d3d11`) game whose DirectX 12 start failed it starts the game once more in DirectX 11
  (`BOTTLE_GAME_ARGS` in `~/.config/steamos-bottle/games/<appid>.env`, which steam-arm64's
  user_settings.py adds to the command line); if that fails too, the setting goes again.
- **GPU numbers in Steam's performance monitor.** The app sends the Mac GPU's load and memory in
  use (its driver's statistics) and the chip's temperature (the hottest die sensor) once a
  second; `bottle-screen` writes them to `/dev/shm/steamos-bottle-host-stats`, and a stand-in
  NVML (`guest/nvml`, linked into Steam's own library folder only) hands them to Steam's
  overlay. `BOTTLE_GPU_STATS=0` in steam.env leaves it out. The CPU clock shows 0.00 MHz: Steam
  reads it from cpufreq, which the VM doesn't have.
- **Performance monitor without its graphs.** In Steam's ARM64 overlay the bar is as tall as its
  tallest part, and the FPS and CPU core graphs' height settings are often left unset (garbage),
  so the bar became a dark band the window's height with the numbers out of view (The Witcher 3,
  its launcher). steam-arm64 turns both graphs off once per Steam user before Steam starts
  (`InGameOverlayShowFPSGraphFPS`/`...GraphCPU` in localconfig.vdf); the numbers stay, and
  graphs switched back on in Steam stay on. `BOTTLE_PERF_GRAPHS=1` in steam.env skips it.
- **Steam's own Compatibility setting sticks.** `bottle-steamplay map` (before every Steam start)
  sets games to Proton Experimental; a game whose setting was changed in Steam since then keeps
  that change (`~/.config/steamos-bottle/steamplay-choices.json`).
- **A game installed while Steam runs** is set to Proton by the watcher with one Steam restart
  (`bottle-steamplay pending`, `playmap_guard`); see "Games installed while Steam runs".


### Why `MESA_KK_DISABLE_WORKAROUNDS=12,13` (10x in D3D11 games)

A Metal System Trace (`bottle gputrace`) of Devil May Cry 5 showed the Mac GPU running every
draw on its own: a small compute job (KosmicKrisp copying the draw's index buffer), then the
draw in a fresh render pass, nothing overlapping. ~30-40 µs per draw, ~1,300 draws per frame,
whatever the resolution: 10-16 fps. The copy is KosmicKrisp's workaround 12/13 for a macOS 26
Metal 4 index-buffer-length bug (fixed in macOS 27; see Mesa's `docs/drivers/kosmickrisp/workarounds.rst`).
With both workarounds off DMC5 went from 10-16 fps to 30-100 fps in gameplay (GPU time per
frame from 60-86 ms to ~6.5 ms; the CPU side is the limit now). The cost: a draw that
reads past the end of its index buffer is no longer made safe, so a misbehaving game could
show broken geometry. `bottle start` adds the setting unless `bottle env --mac` sets it.

## How the pieces fit

| File | Runs on | Does |
|---|---|---|
| `host/setup-host.sh` | Mac | Lima + krunkit, creates/provisions the VM, installs `bottle`, offers KosmicKrisp |
| `host/bottle` | Mac | The daily command above |
| `host/kosmickrisp.sh` | Mac | Relinks krunkit's virglrenderer from MoltenVK to the Vulkan loader + KosmicKrisp |
| `guest/setup-guest.sh` | VM (root) | Fresh VM: Venus Mesa (COPR), FEX + x86 rootfs, Steam deps, then `update-guest.sh` |
| `guest/update-guest.sh` | VM (root) | Idempotent: tools, TigerVNC desktop, both layer builds, x86 Venus, DXVK 2.6.2 cache |
| `guest/steam-arm64` | VM | Downloads/launches the ARM64 Steam client; reads `steam.env`; keeps DXVK applied |
| `guest/bottle-dxvk` | VM | DXVK 2.6.2 next to Windows games' `.exe` (status / apply / remove) |
| `guest/start-desktop` → `bottle-desktop` | VM | Desktop on `:1` (Xvnc, or Xvfb + x11vnc), VNC on `127.0.0.1:5901`; starts at the size the window last asked for |
| `guest/bottle-resolution` | VM | The screen's size (xrandr; Xvnc takes any size as a new mode) |
| `guest/bottle-session` | VM | Game Mode / Desktop Mode (status, install, on, off, configure, steam) |
| `guest/bottle-whyquit` | VM | Why a game closed at launch, as a notice for the window; the DirectX 11 retry |
| `guest/bottle-libraries` | VM | The Mac's game folders as Steam libraries, the default for new games, Steam's tools kept off them (run before Steam starts) |
| `guest/nvml/` | VM | NVML stand-in with the Mac's GPU numbers, for Steam's performance monitor |
| `guest/comet/` | VM (root) | Comet, the open-source stand-in for the GOG Galaxy client's service (`comet-aarch64`, its `MANIFEST`/`BUILT`, the licenses of everything compiled into it; `build-aarch64.sh` rebuilds it), started by `bottle-stores run` for GOG games that use the Galaxy SDK |
| `guest/x86-venus.sh`, `guest/x86-venus/` | VM (root) | Mac-patched Venus driver for the x86 (FEX) side: the COPR's x86_64 build, and our own 32-bit build (`x86-venus/libvulkan_virtio.i686.so`, Mesa 25.3.6 + the COPR's three patches; `build-i686.sh` rebuilds it) for 32-bit Windows games |
| `guest/present-layer/` | VM (root) | The bottle Vulkan layer: CPU-copy swapchain on a presenter thread (never blocks the game on the display; `BOTTLE_PRESENT_SYNC=1` = old path; `BOTTLE_PRESENT_SWAP_RB=1` in steam.env if a game's red and blue look swapped), DXVK feature stand-ins; and the kopper shim (`bottle_kopper.c`) for Big Picture on the GPU |
| `guest/bench` → `bottle-bench` | VM | Baseline report: Vulkan device + features, GL, vkmark, FEX |
| `guest/tso/` → `bottle-tso` | VM (root) | x86 memory ordering in hardware: `bottle_tso.c` (a small kernel module that sets Apple's TSO bit on every CPU of the VM), `bottle_tso_check.c` (static x86_64 test: message-passing litmus on every CPU pair, and a multithreaded memory benchmark; built into `bottle-tso-check.x86_64`) |

**Why DXVK 2.6.2:** Proton's DXVK 3.x requires `VK_KHR_maintenance5` and
`VK_KHR_maintenance6`, which Venus on KosmicKrisp doesn't expose yet. Wine loads DLLs
from a game's own folder first, so `bottle-dxvk` puts 2.6.2 there (only files it added
are ever removed; games that ship their own `dxgi.dll`/`d3d11.dll` are left alone). It
stops applying itself once the GPU has both extensions.

**Sound.** krunkit gives the VM no sound card, and some games crash or hang while starting their
audio when Wine finds no device (DMC5 did, on most launches). `bottle update` sets up PipeWire with
an output for games (`bottle-sink`) that also streams what plays there as raw 48 kHz stereo PCM on
the VM's port 4711. Lima forwards the port, and `bottle start` runs `bottle-audio` on the Mac
(host/bottle-audio.swift, built once with Xcode's `swiftc`), which plays it through the Mac's current
output with ~60 ms of delay. `bottle audio off|on|status`; log in `~/.config/steamos-bottle/audio.log`.

**Disk space.** Games live in a game folder on the Mac or a drive (see "Where games go"), or on
the VM's disk (20 GB since 0.7.0.1, 200 GB before; a file that takes Mac space only as it fills,
and gets it back when files are deleted, since the VM's file system discards freed blocks).
`bottle disk` shows what fills it, what it takes of the Mac now and the Mac's free space;
`bottle disk grow [GB]` makes it bigger (Lima's `limactl edit --disk`, Lima 1.1+: stops Steam
and the VM, resizes, starts it, grows the partition and file system if cloud-init didn't,
starts Steam; refuses sizes the Mac can't hold; default: 10 GB more); `bottle disk clean` clears package caches,
old journal, crash dumps and game logs over 50 MB. The watcher does that by itself when the
VM's disk has under 3 GB free, then warns in the app; under 1 GB it stops a Steam download. A full disk makes Steam crash and restart,
and `bottle update` fail. Switching a game from its Linux to its Windows version briefly needs
room for both.

**Where games go (Oct 12).** The VM's disk can't tell Steam how much room the Mac really has:
inside the VM it looked like 200 GB with plenty free even when the Mac had 20 GB left. So games
go in a **game folder** instead: a plain folder on this Mac (`~/Games/Portalistic`, the default
for new games) or on an external drive, which the Mac shares with the VM (a writable Lima mount
at `/mnt/portalistic/NAME`). Games there are ordinary files on that drive: they take its space
as they install, Steam's install window shows the drive's real free space and refuses a game
that doesn't fit, and uninstalling gives the space straight back.

- `bottle library add ~/Games/Portalistic --default`, `bottle library add /Volumes/SSD` (a
  "Portalistic Library" folder on the drive), or Game Folders > Add a Game Folder… in the app. The VM
  restarts to share it. `bottle library folders` (Game Folders > Show Game Folders) lists them.
- In Steam each one is a library under Settings > Storage, named as on the Mac ("Mac", "SSD").
  Steam's Storage page can move installed games between them, and its Make Default sticks.
- `bottle-libraries` in the VM (run by steam-arm64 before Steam starts) adds each shared folder
  to Steam's `libraryfolders.vdf`, sets the default (`LastInstallFolderIndex` in each user's
  `localconfig.vdf`), and moves Steam's own tools (Proton, the Steam Linux Runtimes, FEX) off a
  game folder onto the VM's disk if Steam put them there: they need a Linux file system, and the
  Mac's ignores the difference between upper and lower case.
- A drive must be connected when the VM starts; one that isn't is left out (Steam shows its
  library as unavailable) until a `bottle restart` with it connected. Eject it only after
  `bottle stop`. Drives must be APFS or Mac OS Extended (not exFAT/NTFS: Wine needs links and
  file permissions).
- Never your Mac Steam's library (e.g. `/Volumes/SSD/SteamLibrary`): Steam in the VM would
  replace the Mac versions of its games with Windows ones. `bottle library add` refuses it and
  any other Steam's library, and makes Portalistic's own folder next to it instead.
- Game folders are excluded from Time Machine (games download again from Steam). Windows saves
  that aren't in Steam Cloud live with the game's prefix in the game folder
  (`steamapps/compatdata`).
- If macOS won't let the VM open a folder (a privacy question for Documents or a drive that was
  answered no), the VM starts without its game folders and says so; allow it in System Settings >
  Privacy & Security > Files and Folders, then `bottle restart`.

**The free-space guard.** While the VM runs, the watcher checks the Mac's free space every
minute. Under 10 GB (`BOTTLE_DISK_LOW_GB`) it has the VM hand back what deleted files freed and
shows a warning in the app (at most every 15 minutes); under 3 GB (`BOTTLE_DISK_STOP_GB`) it stops
a Steam download that's making the VM's disk grow (Steam quits; Steam > Restart Steam brings it
back), before the VM's disk can no longer grow and the VM stops working.

**Staying awake.** A sleeping Mac freezes the VM (downloads, games). While the VM runs,
`bottle` keeps a loop going (started by start / window / vnc, stopped by stop) that asks the
VM every minute what Steam is doing (`bottle-busy`: a game launcher or Wine running = game;
download data written in the last 3 minutes = download) and holds `caffeinate` to match: a
game keeps the system and display awake, a download the system only, idle lets the Mac sleep
as usual (a closed lid still sleeps it). `BOTTLE_AWAKE=0` turns it off; log
~/.config/steamos-bottle/awake.log. Controller input counts as user activity
(IOPMAssertionDeclareUserActivity). In the VM, X never blanks the screen (`-s 0`, xset).

**Windows versions, no fallbacks.** `bottle-steamplay` (run by `steam-arm64` before Steam
starts, since Steam reads these settings only then) sets every installed game to Proton
Experimental in Steam's config.vdf, changing nothing else there; never a tool (anything with a
toolmanifest.vdf: Proton, the runtimes, and FEX, through which Steam's ARM64 client runs every
x86 game; set to Proton once by mistake, FEX broke and every game failed with "Compatibility
tool failed"; the script repairs that). Games with a native Linux version run their Windows version instead: native Linux builds
use OpenGL, which the bottle only has in software (Rocket League's Linux build ran at ~5 fps);
Steam re-downloads such a game as its Windows version. `bottle-dxvk` gives every Windows game
DXVK 2.6.2: a full pass when Steam starts, then every 5 s a quick one for games whose Steam
manifest changed (an install or update finishing), so a game is covered before its first start.
To keep a game native: its app ID in ~/.config/steamos-bottle/native-apps.
An own Steam Play tool (Proton Experimental with DXVK 2.6.2 built in, in compatibilitytools.d)
is there behind `BOTTLE_STEAMPLAY_TOOL=bottle`, but off: Steam's ARM64 client fails to start it
("Compatibility tool failed").

**Crash hunting.** Venus, the games' GPU driver, silently stops a game (abort) when a wait
outlasts ~3.5 s while the Mac side looks unresponsive; `steam-arm64` sets `VN_DEBUG=no_abort`
so it waits instead (`BOTTLE_VN_ABORT=1` in steam.env restores it; a fatal GPU error still
stops the game). With `bottle steam --debug` it also sets `MESA_LOG_LEVEL=debug` (Venus says
why it stops or stalls) and a WINEDEBUG without `+unwind` (one crash otherwise wrote 181 MB of
stack unwinding). `bottle-logkeep` keeps the start and end of big logs plus, from the middle,
the thread names and the first errors. `bottle log export` adds the VM's kernel messages,
crash dumps and abnormal exits, krunkit's own messages and macOS GPU messages.

**The Mac window (Portalistic.app).** VNC only sends where the pointer is, so games that
read raw mouse movement (mouse-look) see huge jumps: the VM's XTest/Xvnc pointer reports absolute
positions as "raw" values. `bottle-screen` (guest/screen, C) streams the X desktop as JPEG frames
(XDamage + MIT-SHM capture, TurboJPEG; ~60 fps at 1080p) on the VM's port 4720 and injects input
with XTest: relative motion as relative motion (verified: XInput2 raw events carry the deltas), and
absolute moves converted to relative ones. It also reports when the pointer is hidden (XFixes), and
the app then captures the Mac's mouse. A press lasts at least 50 ms: games that read the mouse
buttons and keys once a frame missed clicks whose press and release reached the VM together (input
arriving in a burst while the VM was busy), so such a release waits. Its log (screen.log, in `bottle
log export`) notes those quick presses once a minute, any time the server was too busy to take input
for over 250 ms, and every change of the active window (a window taking the focus from a game).
`bottle update` builds it; the desktop starts it. Steam's
main window fills the VM's screen (`bottle-maximize-steam`: only the big window titled "Steam";
its menus and dialogs are separate windows with that title and keep their size), so the app
looks like Steam itself. It stays that way (`bottle-maximize-steam --keep`, running with Steam):
Steam draws its own minimize, maximize and close buttons and the desktop has no taskbar, so a
minimized main window comes back, an un-maximized one fills the screen again and a closed one
reopens (`steam://open/main`) within a second or two; not over a running game (it waits for the
game to end). That's for `bottle ui desktop`; by default Steam runs in Big Picture (below). What
the keeper did: ~/.config/steamos-bottle/steam-window.log. The desktop no longer opens a terminal window (`BOTTLE_XTERM=1` brings it back). VNC stays
available as a fallback (`bottle vnc`).

**Steam's menus.** Openbox sends a focus change before each click, which Steam's drop-down and
right-click menus take as "clicked elsewhere": clicks then land behind them. Valve's fix is
Steam's Settings > Interface > "Enable context menu focus compatibility mode" (`bottle settings`
opens Steam's settings without its menus; `bottle steam-url steam://...` opens any Steam link,
e.g. steam://uninstall/<app id>). `bottle wm xfwm4` / `bottle wm openbox` switch the VM's
window manager in place (Steam and games keep running; the choice is kept).

**Game controllers.** The app reads up to four controllers through Apple's GameController
framework (Xbox, PlayStation DualSense / DualShock 4, other MFi pads) and `bottle-screen`
turns each into a virtual Xbox 360 pad in the VM (uinput, the xpad driver's IDs and events),
which SDL, Proton and games all understand; the game's rumble goes back to the controller
(Core Haptics: strong motor left, weak motor right). PlayStation's Create button and touchpad
click act as Back/View; Home buttons go to the game instead of macOS. Games show Xbox button
icons. The window's subtitle names the controllers in use, in player order. Most games only
listen to player 1, so the controller in use is player 1: when player 1's controller has sat
idle for 30 s and another one is used, they swap places, and when one disconnects the others
move up. Two people playing at once keep their places. `bottle update` loads uinput and
gives the user access (an ACL; a group wouldn't reach processes on Lima's shared ssh
connection until a restart). Once a virtual pad exists it stays plugged in: when the Mac's
controller drops out (Bluetooth) or the app closes, the pad is only centered. Unplugging a pad
mid-game made Devil May Cry 5 stop drawing (sound went on) until the next controller change.
For the same reason `bottle update` waits until no game is running (`bottle update --now`
doesn't); it restarts the screen server, which unplugs the pads.

**Anti-cheat.** Games whose Easy Anti-Cheat allows Proton (Rocket League since April 2026) need
Valve's Proton EasyAntiCheat Runtime, a Steam tool that holds the anti-cheat's Linux side. Steam
on a PC installs it by itself; the ARM64 client here doesn't: `bottle anticheat` asks Steam for
it (tool 1826330), waits until it's installed and restarts Steam, and `steam-arm64` points Proton
at it (`PROTON_EAC_RUNTIME`; `PROTON_BATTLEYE_RUNTIME` likewise for BattlEye's). Whether the
anti-cheat then accepts a VM running x86 code through FEX is up to it: nothing here hides either
from it. `bottle log export` includes the anti-cheat's logs. Games whose anti-cheat doesn't allow
Proton at all can't work. Tested 2026-10-08 with Rocket League: with the runtime in place, EAC
recognizes Proton (`System name: 'linux64'`) and downloads its Linux module, then stops at
"Starting Wine module mapping" with code 210 ("Unexpected error. (#1)"), inside its own code (no
error from Wine or FEX). So EAC doesn't run under FEX here; playing without anti-cheat (training,
offline, LAN, replays) works.

**The picture.** `bottle-screen` sends only the rectangle that changed (XDamage bounds, in
whole 16-pixel JPEG blocks; Steam's menus are often a few KB per update instead of ~100 KB),
and 150 ms after the screen goes still a sharp copy of what changed (quality 95, 4:4:4: no
colour smearing on text). It captures the next frame while the last one is still being
encoded. Older apps keep getting whole frames. The app draws every piece into one picture and
shows it with Metal: MetalFX's spatial scaler enlarges the VM's 1920×1080 to the window's real
(Retina) pixel size, which keeps edges and text crisper than plain stretching, in step with the
display. View menu: **Sharp Scaling (MetalFX)** (off: plain smooth scaling), **Smooth Motion**
(asks for as many frames as the display shows, up to 120 on ProMotion; off: 60) and **Show
Stream Info** (⌥⌘I: updates per second, sizes, decode time, and the VM's capture/encode times).
The VM's screen itself stays 1920×1080: games render at their own setting, and a bigger desktop
would cost every frame.

**The app on its own.** After the first `bottle window` (which builds it into ~/Applications),
Portalistic opens from the Dock, Launchpad or Spotlight like any app: when the bottle isn't
running it runs `bottle _up` (VM, desktop, Steam, sound, keep-awake) and shows each step on its
starting screen, or what went wrong (Show Log opens the output, in the kit's `logs/app-*.log`).
Its **Steam** menu has the everyday commands: Start the VM, Restart Steam, Open Steam
Settings, Update the VM, Save Logs for Claude (shows the file in Finder), Show Activity (their
output) and Shut Down the VM. The app's Info.plist records the kit folder and the PATH at build
time (opened from the Dock an app gets a bare PATH, without Homebrew's limactl). When a file in
host/Portalistic/ is newer than the app (a kit update, or an edit in Xcode), the app rebuilds
itself on launch (`bottle _rebuild`) and reopens; if that build fails, the old one carries on and
logs/app-build.log says why. The icon is
host/AppIcon.icns (drawn by host/make-icon.py). Keep it in the Dock: right-click its Dock icon >
Options > Keep in Dock.

**The app's code** is in host/Portalistic/, by area: App/ (the entry point and AppDelegate,
split into extensions: starting the bottle, menus, picture settings, quitting), Stream/ (the
screen protocol, the connection, the picture), Display/ (the Metal renderer and the view that
takes input), Input/ (controllers, rumble, keyboard map) and Bottle/ (running the `bottle`
command, the starting screen, the Activity window). The Xcode project includes the whole folder (a synchronized folder,
Xcode 16+): a new file there is part of the app without touching the project.

**Building the app with Xcode.** `bottle xcode` opens host/Portalistic.xcodeproj (one target
over host/Portalistic/, macOS 26+, Apple Silicon) and sets your signing team: it reads the
team from your Apple Development certificate into host/xcode/Team.xcconfig (not part of the kit,
so updates keep it); with several teams or none yet, choose it in Xcode under Signing &
Capabilities. ⌘R builds and runs a debug copy (errors show in Xcode). Once a team is set,
`bottle window` and the app's self-update build ~/Applications/Portalistic.app with
`xcodebuild` (Release, signed with your team, hardened runtime, no sandbox: the app runs the
kit's `bottle` command and talks to the VM on 127.0.0.1); the build log is logs/app-build.log.
Without Xcode or a team the app is still built with `swiftc -parse-as-library` (every file in the
folder) and signed ad hoc.

**Big Picture.** The window shows Steam in Big Picture, as on SteamOS: games, store, downloads,
settings and the controller-friendly menus come from Steam itself. `steam-arm64` starts Steam with
`-gamepadui`, and `bottle-maximize-steam --keep` keeps it there: leaving Big Picture opens it
again (`steam://open/bigpicture`), a minimized or windowed Big Picture comes back full screen, and
a Steam that quits (Exit Steam in its power menu, a crash) starts again after 10 s, unless the
bottle stopped it (`bottle steam`, `bottle stop`). None of that happens while a game runs. `bottle
ui desktop` switches to Steam's desktop windows (kept maximized and on screen the same way),
`bottle ui bigpicture` back. The app's earlier home screen, the Library, is kept in
host/archive/library-screen/ (`bottle library` and `bottle play APP_ID` still work from Terminal).

**Big Picture on the Mac's GPU (experimental; works since Oct 9, smoother than on the CPU).** Steam's interface is Chromium, which draws with
OpenGL; the VM has OpenGL only in software (llvmpipe, on the VM's processors), so Big Picture's
animations stutter. `bottle steam-gpu on` runs Steam's OpenGL through Mesa's zink, which turns it
into Vulkan: here Venus on the Mac's GPU, presented by the bottle layer like a game's frames. It
first checks that zink works in the VM (glxinfo must report zink on Venus; glxgears shows a gears
window for a few seconds, once on the CPU and once on the GPU, with their frame rates), then
restarts Steam with `MESA_LOADER_DRIVER_OVERRIDE=zink LIBGL_KOPPER_DRI2=1` (Xvnc has no DRI3,
which Mesa otherwise wants for zink; zink presents through Vulkan instead). `bottle steam-gpu off`
goes back; `bottle steam-gpu` says which is on. After the restart it waits for Big Picture and looks
at the VM's screen (xwd): if Big Picture stays black, it goes back by itself and keeps that
session's Steam log for `bottle log export`. It also goes back after about 20 s if Steam's web
helper logs "failed to initialize GL thread" twice, and on Ctrl-C. When it works it names the
renderer Steam's GPU report shows. The GPU session also logs the bottle layer's work with Steam's
frames (BOTTLE_PRESENT_DEBUG=1). Native Linux OpenGL games started from Steam get zink too.

The first tries on the Mac (Oct 9) were black for this reason. Steam's client sets
`LIBGL_KOPPER_DISABLE=true` for steamwebhelper ("to get store working properly"). Without kopper,
zink can show frames only through DRI3, so Mesa refuses the web helper an OpenGL context: its
compositor logs "CreateOutputWindow: failed to acquire a gl context" and restarts every 10 s. The
fix is the kopper shim, guest/present-layer/bottle_kopper.c, which the layer installer builds as
/usr/local/lib64/libbottle_kopper.so. In this mode steam-arm64 sets it up two ways:

- **Preloaded into Steam** (`LD_PRELOAD`). It wraps execve, the rest of the exec family and
  posix_spawn. Programs Steam starts with zink in their environment get `LIBGL_KOPPER_DISABLE=0`.
  The preload stays on Steam and its web helper and is taken off everything else Steam starts,
  so games and x86 programs never get it. The wrappers use only the stack and system calls, so
  they're safe in a vfork()ed child.
- **Linked as libGLX_mesa.so.0 and libEGL_mesa.so.0** into the folder on Steam's LD_LIBRARY_PATH
  (~/.local/share/Steam/lib/aarch64-linux-gnu). GLVND then loads it in place of Mesa's vendor
  libraries, and it hands over to Mesa's real ones. The links are removed when the mode is off.

Why both: the Oct 9 morning try had only the links, and it never reached the web helper. Steam
starts the web helper with a library path of its own, and there was no shim line in its log.
Wherever the shim loads, it also sets the variable to 0 in its own process.

It logs to ~/.cache/steamos-bottle/kopper.log (which programs loaded it, which programs it
fixed), rotated at each Steam start.

`bottle steam-gpu on` checks the same way Steam will start its web helper:

- The shim is preloaded into a parent that then sets `LIBGL_KOPPER_DISABLE=true` and starts
  glxinfo, glxgears, and bottle-gltest (present-layer/bottle_gltest.c).
- bottle-gltest is a transparent depth-32 window through GLX and through EGL, read back from the
  screen. GLX must show on zink on Venus. EGL failing is reported but not required.
- When Big Picture fails, it saves what Steam and its web helper run with to
  ~/.config/steamos-bottle/steam-gpu-diag.txt: their settings, the OpenGL libraries they loaded,
  and kopper.log. It prints the main points. Save Logs includes both files.

**Oct 9, 10:45: still black, and the logs showed why.** The shim did run in every web helper
process and reset the variable, so that wasn't what blocked it any more. The real blocker:
through zink, the Mac's GPU offers only OpenGL 2.1. The zink check reports "Max core profile
version: 0.0". Venus on KosmicKrisp has no transform feedback, so zink can't offer OpenGL 3.0 or
GLES 3.0, and no geometry shaders, so it has no core profile, which starts at 3.2. Steam's
compositor asks for more and gets nothing.

The fix: the bottle layer reports those features to zink the same way it already does to DXVK
(`BOTTLE_FAKE_ZINK=1`, which steam-arm64 sets in this mode).

- It applies only to instances whose engine is "mesa zink". Transform feedback becomes the
  layer's no-op stand-in. The other features are reported and then dropped when the device is
  created.
- Steam's interface never uses them. zink could still generate a geometry shader internally (for
  line stipple, or provoking vertex if the GPU lacked VK_EXT_provoking_vertex, which KosmicKrisp
  has). The layer logs it once if a pipeline with a geometry shader is ever created.
- `bottle steam-gpu on` now needs bottle-gltest's OpenGL 3.3 core transparent window to show
  through GLX on zink-on-Venus. EGL is reported.
- Save Logs records zink's maximum versions with the stand-ins.

Tested on lavapipe with a test layer under the bottle layer that hides geometry shaders and
transform feedback, the same gaps as Venus:

- Without the stand-ins: core 0.0, compat 2.1, GLES 2.0, and a 3.3 core context fails with
  GLXBadFBConfig. That is Steam's "failed to acquire a gl context".
- With them: core 4.6, GLES 3.2. GLX and EGL 3.3 core windows draw and show, glxgears runs, and
  Chromium draws through ANGLE.
- No geometry-shader pipeline was created in any of those tests.

**Oct 9, 11:06: stopped at the check.** With all the stand-ins, zink on the Mac offered OpenGL
3.3 core and GLES 3.1. But the check stopped after glxgears, and Steam wasn't restarted. At those
moments the Mac logged "(Metal) Compiler failed to build request". There was no record in the
VM of what went wrong.

The check now records everything and tunes itself:

- It writes ~/.config/steamos-bottle/steam-gpu-check.txt: what Vulkan reports for the Mac GPU
  (vulkaninfo: the relevant extensions and features), then glxinfo, glxgears and bottle-gltest
  output for each try, with the layer's debug lines.
- It tries the stand-ins from the fewest up: `geometryShader`; then geometryShader with
  depthClamp, dualSrcBlend, independentBlend and fillModeNonSolid; then all of them. It keeps
  the first set that gives a core profile, glxgears frames and the 3.3 core GLX window, and saves
  it to steam-gpu-fake. steam-arm64 reads that file (default `geometryShader`).
- Whenever the check or the Steam restart fails, it saves the logs itself (Save Logs).

**Oct 9, 11:37: what the check found.** The Mac GPU, as Vulkan reports it, has
VK_EXT_provoking_vertex but no geometry shaders, no transform feedback, no VK_EXT_shader_object
and no extended_dynamic_state3. With the `geometryShader` stand-in, zink offered OpenGL 3.3 core
and GLES 3.1. But glxgears crashed (core dump) right after the layer logged "a pipeline with a
geometry shader was created". glxgears draws GL_QUADS, and once zink believes in geometry
shaders it draws quads through one, which the Mac GPU can't run. Without the stand-in it splits
quads on the CPU. Steam and Chromium draw triangles, which take no such path.

So the check no longer uses glxgears with the stand-ins. bottle-gltest's core mode now draws
like a compositor: it compiles a GLSL 3.30 vertex and fragment shader, samples a texture and
draws a triangle over a dark-blue clear. The orange must come back from the screen. The VM is
updated if its bottle-gltest is older.

Not kept: taking zink's own geometry shaders out of its pipelines. On a test GPU without
VK_EXT_provoking_vertex, zink draws flat shading through one, and without it glxgears came out
as lines instead of filled shapes.

Tested here on Xvfb with lavapipe standing in for Venus, through the bottle layer's CPU-copy
swapchain:

- A fake Steam started programs every way Steam might: posix_spawn, posix_spawnp, fork+execve
  with a hand-built environment, vfork+execv, execle, and system(). Each one got
  `LIBGL_KOPPER_DISABLE=0`. The web helper kept the preload; a "game" lost only the shim's entry.
  Nothing changed without zink.
- With Steam's variable, an SDL window on EGL fell back to llvmpipe. With the shim preloaded
  into the fake Steam, it ran on zink and showed.
- bottle-gltest showed for GLX and EGL, ARGB and RGB.
- This machine's Mesa (25.2) still gives GLX zink despite the variable. The VM's Mesa 25.3, like
  26.2's source, doesn't.

**The GPU mode is for Steam's interface only (Oct 9).** The Witcher 3's launcher
(REDprelauncher.exe) quit seconds after starting. Its OpenGL had gone through zink too: the
x86 game processes inherited MESA_LOADER_DRIVER_OVERRIDE=zink, and zink without the stand-ins
offers only OpenGL 2.1 on this GPU.

steam-arm64 now lists the settings it adds for the mode in BOTTLE_GPU_UI_VARS. The shim,
preloaded into Steam, removes them from every program Steam starts except Steam itself and its
web helper. Games and their launchers then use OpenGL on the CPU, as before the mode existed.
Tested with a fake Steam: a "game" started by posix_spawn, execle or system() gets none of the
settings, while the web helper keeps them all.

**DXVK 2.6.2 everywhere, not just next to the game (Oct 9).** The first light log said why the
Witcher still crashed. REDprelauncher starts CD Projekt's REDlauncher, which lives in the
prefix (AppData\Local\Programs\CD Projekt Red\REDlauncher), outside the game folder. Its
Qt draws through d3d9, which came from Proton's DXVK 3.1.1 in system32. DXVK said "Skipping:
Device does not support required feature 'maintenance5' … No adapters found" and threw (wine:
Unhandled exception 0x20474343 in d3d9). Any launcher installed into the prefix (EA app,
Ubisoft Connect, Rockstar, REDlauncher) would hit the same.

bottle-dxvk now also puts 2.6.2 into every Proton (files/lib/wine/dxvk/{x86_64,i386}-windows,
or lib64/lib on older ones). It keeps Proton's DLLs as <dll>.bottle-orig, so prefixes Proton
sets up get 2.6.2, and it replaces the DXVK DLLs in every game's prefix (system32 / syswow64).
Wine's own builtin DLLs there (WineD3D games) are left alone. The watcher (every 5 s) only
stats files unless something changed, so a Proton update is undone at once. `bottle-dxvk
remove` puts Proton's originals back everywhere. Tested on a fake library: two Proton layouts,
a prefix with a builtin DLL, a Proton update and removal. A quick pass takes 0.05 s.

**The VM keeps up with the kit by itself (Oct 9).** The DXVK fix above sat on the Mac and was
never installed: the try that followed still ran Proton's DXVK 3.1.1, under a Steam started
before the fix arrived. bottle update now leaves a fingerprint of the kit's guest/ folder in the
VM (~/.cache/steamos-bottle/kit-stamp). When the app starts the bottle (`_up`) or Steam is
restarted (Steam > Restart Steam, `bottle steam`), a VM that's behind the kit is updated first.
It doesn't do this while a game runs: it says so, and the update waits for the next time.

**Every launch leaves a light game log.** Without `--debug`, steam-arm64 now sets PROTON_LOG=1
with WINEDEBUG=+timestamp,+pid,+loaddll. That records Proton's setup, the DLLs a game loads
(so whether it runs DirectX 11 or 12), Wine's errors and DXVK/vkd3d messages. Nothing is traced
per frame. bottle-logkeep keeps one log per launch, and Save Logs exports them.
`PROTON_LOG=0` in steam.env turns it off. `--debug` still gives the full tracing.

**Why a game can run worse here than in Heroic or CrossOver, and what the bottle does about
it (Oct 9).** The Witcher 3 (the DX11 "classic" 1.32 build) played with sudden freezes and a
low frame rate, where Heroic on the same Mac ran it better. Heroic runs a Windows game straight
on macOS: Wine translated by Rosetta 2 (ahead of time, with the CPU's x86 memory ordering on)
and Direct3D turned into Metal in one step (D3DMetal or DXMT). Here a game's x86 code goes
through FEX inside a VM, its Direct3D through DXVK into Vulkan, Venus carries every call out
of the VM, KosmicKrisp turns it into Metal, and each frame is copied and streamed to the app.
Each layer costs a little; three of the costs are big and can be cut:

- **Freezes when something new appears on screen: shader compiling.** The GPU has no
  graphics pipeline libraries (`DXVK: Graphics pipeline libraries not supported`), so DXVK
  compiles a whole pipeline the first time a draw needs it, and the game waits while the Mac
  turns it into Metal. bottle-dxvk now puts Ph42oN's dxvk-gplasync 2.6.2-1 in place of plain
  2.6.2 (update-guest.sh fetches it; md5 from Bottles' component list; plain 2.6.2 stays the
  fallback), and steam-arm64 sets `DXVK_ASYNC=1`: a draw whose pipeline isn't ready yet is
  left out for a frame or two while it compiles in the background. Objects can pop in late
  the first time; the game doesn't stop. Compiled pipelines go into DXVK's state cache, so the
  next start compiles them while loading. `DXVK_ASYNC=0` in steam.env, or in one game's launch
  options (`DXVK_ASYNC=0 %command%`), turns it off. Copies of the earlier plain build are
  recognized and replaced (Proton's own DLLs stay kept as `.bottle-orig`); tested on a fake
  library, including the stamps file of the earlier version.
- **Slow game logic: FEX's x86 memory ordering.** x86 programs count on x86's strict memory
  ordering; Arm's is looser, so for every multithreaded x86 program (every Windows game: Wine
  alone runs several threads) FEX turns each memory access into an ordered one. Apple's cores
  can order memory the x86 way in hardware (ACTLR_EL1.TSOEN; that's how Rosetta is fast), and
  since macOS 14.4 Apple's hypervisor lets a Linux guest switch it on (AIDR_EL1 bit 9 says so;
  Apple's own Linux patches, "tso: aarch64: Expose TSO for virtualized linux on Apple Silicon",
  April 2024, not in mainline). `bottle tso on` builds bottle_tso.ko for the VM's kernel (with
  kernel-devel from Fedora, or from Fedora's build system for an older kernel), then proves it:
  the litmus test (writer stores A then B, reader loads B then A; x86 ordering means A ≥ B)
  must show out-of-order reads with FEX's ordering off and the module off, and none with the
  module on, on every pair of CPUs; Steam's own FEX is tested too when it's there (it must take
  `FEX_TSOENABLED`). Then it times a multithreaded x86 workload both ways and keeps the module
  loaded at boot. At every Steam start, `bottle-tso check` repeats the test briefly (and wants
  the kernel it was tested on) and only then does steam-arm64 set `FEX_TSOENABLED=0` for
  games; a failed `bottle tso on` drops an earlier success. After a kernel update, `bottle
  update` rebuilds the module, and games get the hardware ordering again after the next
  `bottle tso on`. Arm programs in the VM keep working (TSO is the stronger ordering), a little
  slower. The module reads its registers and tries the bit once on one CPU (putting it back) as
  it loads, before any lock or sysfs file exists, so a hypervisor that refuses costs only that
  module load; on and off refuse to run under a Steam whose games may rely on the ordering. The test program was checked on this Mac's Apple cores
  (natively, in another Linux VM): about half of all reads come back out of order without TSO,
  so a single unordered CPU can't hide. Not yet run in the bottle's own VM (krunkit uses
  Hypervisor.framework; Apple's patches don't say whether that VM type gets the bit too).
- **Not knowing where the time goes.** The layer now writes a pacing line into every game's
  log every 10 s of play, without `--debug`: frames per second, the slowest frame, how many
  took over 50 and 100 ms (the hitches a player sees), and how many pipelines the game had
  compiled and how long that took (`BOTTLE_PRESENT_PACE=0` turns it off; Steam's own interface
  doesn't write it). The first time a game creates a pipeline with a geometry shader (which this
  GPU lacks, so what it draws may be missing) it says so too. And while a game runs, the
  keep-awake loop writes `bottle perf` every 30 s to the kit's `logs/game-perf.log`, now with the
  VM's busiest processes beside the game (e.g. Steam's interface drawing behind it).

**The Witcher 3 got slower after two minutes: the VM's file cache on the Mac's memory (Oct 9,
17:00).** With async shaders and hardware TSO on (the test passed in this VM: 1.75x on the x86
workload, Steam's FEX included), the pacing lines showed 50-60 fps with almost no hitches for
the first 2-2.5 minutes of both sessions, then a slide to 14-18 fps with 60-95 frames over
50 ms per 10 s, while no shaders were compiling. Pipeline compiles slowed from ~40 ms to 1-5 s
each at the same time: the whole Mac had slowed down, not the game. macOS logged its Metal
compiler service dropping out at each session's start ("may have been jetsammed", the memory
pressure killer), and the VM's file cache held 12.5 GB. Every page the VM touches is memory
on the Mac (18 GB for the VM), next to the game's GPU memory, which also lives there.
`bottle-memtrim` (a service in the VM) kept the file cache near 3 GB (cgroup v2 memory.reclaim,
`swappiness=0`, at most 1 GB a round every 5 s) and had free memory handed back to the Mac in
128 KB pieces (free page reporting order 5 instead of the kernel's 9). It worked (krunkit at
9-13 GB instead of 18, the Mac at 61-66% free), but the game then crashed on all three launches
within 30 s, each time together with the Mac side refusing a GPU submission (virtio-gpu SUBMIT_3D,
response 0x1200, in the VM's journal at the second; Wine: "Exception frame is not in stack
limits"). That signature is older (DMC5's early crashes on Oct 7, CS2 today), but the Witcher had
just played for minutes without it. So `bottle update` turns the trimmer off again and puts the
reporting order back; `bottle memory 12` (a third of a 36 GB Mac) caps the VM's share of the
Mac's memory instead. The Mac had 21 GB in swap by then. Its thermal pressure stayed at 0 in
these (short) sessions' samples; a long one hasn't been sampled yet. Also, `bottle perf` (and game-perf.log) now also records the Mac's thermal pressure
level, memory pressure level, free memory, swap, the VM's memory on the Mac, power source and
low power mode, and the Mac's busiest processes, and the VM's memory and pressure (PSI). The
keep-awake watcher restarts itself when the bottle command changes (it had kept running the old
code, so the first session recorded no samples). Also seen: The Witcher 3 builds a few pipelines
with geometry shaders (particles); KosmicKrisp fails them (`VK_ERROR_INVALID_SHADER_NV`, Metal
"type 'uint4' is not valid for attribute 'position'"), so those effects are missing.

**Big Picture back on the GPU (Oct 9, 17:30).** Since the GPU-mode leak fix (14:03), Big Picture
had been drawing on the CPU again (the web helper's GPU report: ANGLE on llvmpipe; ~3.5 VM cores
busy behind a running game). Steam starts its web helper through `sh`, and the shim took the GPU
settings off that `sh` like off any other program. A first fix (keep them for a shell whose
arguments name steamwebhelper) didn't reach it: the `sh` Steam starts doesn't name it. Now the
mode's settings stay out of Steam's environment altogether: steam-arm64 exports only
BOTTLE_STEAM_GPU=zink and BOTTLE_STEAM_GPU_FAKE (the stand-ins), Steam isn't preloaded any more,
and the shim, which GLVND loads as Mesa's vendor library in every process on Steam's library
path, sets MESA_LOADER_DRIVER_OVERRIDE=zink, LIBGL_KOPPER_DRI2=1 and BOTTLE_FAKE_ZINK inside
steamwebhelper processes only (by /proc/self/exe), before Mesa reads them. Nothing Steam starts
can inherit them. Tested with glxinfo renamed to steamwebhelper (zink requested; "failed to load
driver: zink" on this test machine's CPU-only Vulkan, as expected) and under another name
(llvmpipe, no settings).

**What slows The Witcher 3 after two minutes: the Mac's GPU at 99% and the Mac getting hot (Oct 9,
17:25).** With the VM at 12 GB (`bottle memory 12`), memory is no longer a factor: krunkit at
6-12 GB, the Mac 54-76% free, memory pressure normal. The snapshots now show the GPU busy 97-99%
from the moment the game is in the world, the game's threads in the VM at 10-35% (CPU isn't the
limit), and the Mac's thermal pressure going from 0 to 2 ("heavy") about 1.5 minutes in, after
which the frame rate slides 57 → 55 → 51 → 48 → 46 → 43 → 39 → 37 → 33 fps as macOS slows the
chip. So the game's GPU work, after DXVK, Venus and KosmicKrisp, is enough to keep the Mac's GPU
fully busy at ~55 fps at 1080p, which Heroic's direct path (D3DMetal/DXMT) apparently doesn't
need. Next: a Metal System Trace (`bottle gputrace`, which now also leaves its zip and a
`bottle perf` snapshot in the kit's logs/) to see where the GPU time goes, as with DMC5 (where it
found KosmicKrisp's per-draw index copies, a 10x win). KosmicKrisp's own workaround list
(docs.mesa3d.org/drivers/kosmickrisp/workarounds.html) has candidates with a GPU cost in every
shader: 6 (device memory pointers marked coherent) and 14/17 (the `safe` math pragma, no fast
math).

The trace (Oct 9, 18:54, 4 s; taken as the Mac was already at thermal pressure 2, the GPU in its
"Medium" performance state 80% of the time, and the game at ~25 fps while xctrace ran; the
device is "mobile": a MacBook Pro): krunkit was the only real GPU user (WindowServer, the app
and a browser ~5% together). Per frame, roughly: ~86 render passes (8,576 in the trace, ~6,600
of them under 100 µs, ~1.7 ms together; ~11 longer than 300 µs, ~8.5 ms together: the game's
real passes) and ~20 compute passes (one ~1.3 ms pass every frame, often a ~1.0 ms one 2 ms
later), about 14 ms of GPU time per frame at the reduced clock. On the CPU side KosmicKrisp's
single ring thread (vkr-ring-7) encodes alternately a render and a compute encoder (11,574
compute encoders encoded against 2,042 that ran anything on the GPU: most are empty, likely
barriers), busy 34% of the time at ~25 fps, so near a whole core at 60. No GPU counters (the
Metal System Trace template records only "RT Unit Active"). Nothing like DMC5's one-copy-per-draw;
the work is the game's own passes, translated. Next experiments: KosmicKrisp workarounds 6/14/17
off (`bottle env --mac MESA_KK_DISABLE_WORKAROUNDS=6,12,13,14,17`, `bottle restart`), comparing
GPU busy and fps at the same spot; and `bottle fps` to stay under the thermal cliff.

**KosmicKrisp workarounds 6, 14 and 17 off: 60 fps held (Oct 9, 21:04-21:08).** Witcher was run
with `MESA_KK_DISABLE_WORKAROUNDS=6,12,13,14,17` in High Power energy mode. Compared with the same
spot at 12,13 (20:50, also High Power):

- Frame rate: 59.8 fps (the game's 60 Hz limit) from the first minute, and 54-58 at the end
  (~3 min). Before: 53-58, then 45, then 40, then 32-36 after ~2 min.
- GPU: 74-82% busy at 60 fps (one spike to 97%), about 13 ms of GPU per frame. Before: 97-99% at
  ~55 fps, about 17.6 ms per frame. That is ~25% less GPU work per frame.
- Heat: thermal pressure still reached 2 after ~2 min, but the frame rate stayed at 54-60.
- Shaders: the first run after the change compiled them again, because the settings are part of
  the shader cache key. 198 pipelines took 27.9 s (longest 1.2 s), against 0.7 s from cache, and
  there was one 2.3 s freeze while entering the world. Later runs should hit the cache again.

No flickering or other visible problems (Michael, 21:10). Now the kit's default (it was 12,13); a
`MESA_KK_DISABLE_WORKAROUNDS` line already in host.env wins over it. A game that renders wrongly
with it: `bottle env --mac MESA_KK_DISABLE_WORKAROUNDS=12,13` and `bottle restart`. DMC5 still to
be checked with it.

**Counter-Strike 2 crashing while it builds shaders: pipelines are now created with an answer (Oct 9,
21:45).** CS2 stopped drawing after it loaded its menu, then either closed silently or crashed.
- What the logs show: a virtio-gpu SUBMIT_3D refused by the Mac (0x1200), then Wine's "Exception
  frame is not in stack limits". This is the same signature as the earlier Witcher, DMC5 and CS2
  crashes.
- Venus creates a pipeline asynchronously when the calling thread records or submits. For DXVK
  that is the CS thread, which creates every compute pipeline and the graphics pipelines it
  can't give to a worker. The call returns success at once and the Mac builds the pipeline later,
  in line on the main ring (`vn_get_target_ring` / `vn_CreateGraphicsPipelines` in Mesa 25.3
  `vn_pipeline.c`).
- If the Mac can't build one, the pipeline never exists there, and the first command buffer that
  uses it is a fatal error for the whole GPU context: device lost, then DXVK's exception. Before
  the 18:57 Witcher crash, macOS logged "(Metal) Compiler failed with XPC_ERROR_CONNECTION_INVALID"
  in krunkit.
- The fix: for games, the present layer adds `VK_PIPELINE_CREATE_EARLY_RETURN_ON_FAILURE_BIT` to
  every pipeline creation. That is in Venus' `VN_PIPELINE_CREATE_SYNC_MASK`, so the call waits for
  the Mac's answer. A failure comes back as an error that DXVK logs and survives (it skips what that
  pipeline would draw), and the layer logs "the Mac couldn't build a … pipeline (result N)".
- The wait costs about the same as before: the asynchronous build held up the main ring for as
  long. Not applied to Steam's own interface (zink). `BOTTLE_SYNC_PIPELINES=0` turns it off.
- Tested on lavapipe (pipelines are created and the app's create infos are left unchanged). On the
  Mac (21:49-21:55): CS2's menu ran at 90-100 fps after building 819 pipelines, with no failures and
  no crash.

**Steam's FPS counter and in-game overlay (Oct 9, 23:00).** Steam draws its FPS counter, Shift+Tab,
screenshots and in-game pop-ups with its in-game overlay. This ARM64 Steam has the x86 overlay
files (ubuntu12_64/gameoverlayrenderer.so, steamoverlayvulkanlayer.so), but nothing of it shows
in x86 games.
- Stand-in for the FPS counter: the present layer draws the game's presents per second into every
  frame it copies to the window. It reads Steam's own setting (In-game FPS counter, i.e.
  `InGameOverlayShowFPSCorner` in the newest `userdata/<id>/config/localconfig.vdf`: 1 top left,
  2 top right, 3 bottom right, 4 bottom left; `InGameOverlayShowFPSContrast` for white on black),
  and re-reads it every 2 s. `BOTTLE_FPS_COUNTER=0` turns it off and `=1`-`4` forces a corner. It
  is not drawn on Steam's own interface.
- To find out why the real overlay is missing, each game's log now has a "Steam overlay here:"
  line. It says whether gameoverlayrenderer.so and steamoverlayvulkanlayer.so are loaded in the
  process, whether Steam asked for the overlay's Vulkan layer (ENABLE_VK_LAYER_VALVE_steam_overlay_1),
  LD_PRELOAD, and which library sits right below this layer.
- An overlay layer must sit above this layer (nearer the game) to see frames, because this layer
  answers the swapchain calls itself.

**Steam's in-game overlay, brought into games by the present layer (Oct 10, 18:45).**
- What the game logs showed (DMC5 and appid 2358610): Steam asks for the overlay
  (ENABLE_VK_LAYER_VALVE_steam_overlay_1=1, SteamOverlayGameId set), but nothing of it is in the game
  process: LD_PRELOAD is empty, and steamoverlayvulkanlayer.so isn't loaded. The layer right below
  the present layer is Mesa's device_select.
- Why: Steam's container launcher (pressure-vessel) is the arm64 build here and can't work out x86
  library paths (its x86_64 helpers are missing: "x86_64-linux-gnu-detect-platform: command not
  found"). So it drops the x86 gameoverlayrenderer.so preload and the overlay's Vulkan layer.
- The fix: in the game's first vkCreateInstance, the present layer loads gameoverlayrenderer.so
  (RTLD_GLOBAL) and steamoverlayvulkanlayer.so from Steam's ubuntu12_64 (STEAM_COMPAT_CLIENT_INSTALL_PATH,
  /s, ~/.local/share/Steam), negotiates with the overlay layer, and puts it in the chain right
  above itself. The loader calls the layer's outer entry points, they hand every call to the
  overlay layer, and the overlay layer's next layer is the present layer's inner entry points.
  vkCreateInstance and vkCreateDevice get an extra link for it.
- This happens only when Steam asked for the overlay, never in Steam's own interface, and not when
  the loader already loaded the overlay layer. `BOTTLE_STEAM_OVERLAY=0` turns it off. While it is
  hosted, the layer's own FPS counter is off, because Steam draws its own.
- Tested here with a mock overlay layer on Xvfb and lavapipe: it sees vkCreateSwapchainKHR and every
  vkQueuePresentKHR, and frames still arrive. Without the request, with BOTTLE_STEAM_OVERLAY=0, and
  with the files missing, the layer behaves as before.
- Not known yet: whether Valve's overlay, loaded this late rather than preloaded, sees Shift+Tab
  under Wine, and whether it talks to the ARM64 Steam client. Steam's performance monitor values
  come from Steam's own measurements inside the VM; the VM has no temperature sensors.
- First try (18:58 and 19:04): both parts were loaded and reported to Steam, and Steam started its
  overlay UI process (steamrtarm64/gameoverlayui -pid <game> -steampid … -gameid …). Each one
  crashed at once, six per game start: SIGSEGV in `_dl_close`.
- Why: the tiny launcher dlopen()s libtier0_s.so, libvstdlib_s.so and gameoverlayui.so in a
  constructor, and dlclose()s all three on exit without checking. gameoverlayui.so failed to load,
  so dlclose(NULL) crashed.
- The cause of the load failure: `ld.so --list` reports "libdav1d.so.6: cannot open shared object
  file". gameoverlayui.so finds its direct dependencies through RUNPATH $ORIGIN (steamrtarm64),
  but its libavif.so.16 needs libdav1d.so.6, which is also in steamrtarm64 and on no search path.
  Steam's library path here is only the launcher's own lib/aarch64-linux-gnu.
- Fix: at every start steam-arm64 asks the loader what gameoverlayui.so can't find and links just
  those from steamrtarm64 into lib/aarch64-linux-gnu (overlay_ui_libs).
- While this is being worked on, steam-arm64 also sets STEAM_OVERLAY_LOGGING=1, and the log export
  collects /tmp/gameoverlay*.log. The awake watcher saves the logs when a file
  `logs/.export-now` appears in the kit.
- Second try (19:23), with the UI libraries linked: gameoverlayui stayed up, and Steam created the
  in-game overlay browser (gamepadoverlay_uid<pid>, "SP Overlay", 1920x1081) with its menus.
- But the renderer's log said `ValveGetOutputBounds( 0, 0, 100, 100)` and `SetScaleFactors( 19.20,
  10.80, …)`, and the web helper said "Invalid browser dimensions: 0 x 0". The overlay was laid out
  for a 100x100 window and stretched, which showed up as a few thin coloured lines. Loaded late
  (dlopen), the renderer misses what it learns by being preloaded: the X display and window the
  game opens (it interposes XOpenDisplay, XCreateWindow…) and its keyboard input (XNextEvent…).
- Fix: steam-arm64 writes `user_settings.py` next to each Proton's `proton` script. Proton applies it
  to the game's environment inside the container, so it puts ubuntu12_64/gameoverlayrenderer.so
  back in LD_PRELOAD, only when Steam asked for the overlay (and not with BOTTLE_STEAM_OVERLAY=0).
  A user_settings.py of someone's own is left alone. The present layer still hosts the overlay's
  Vulkan layer, since the container doesn't pass that in.
- Result (19:32, Abathor): **Shift+Tab opens Steam's menu in the game.** Steam's FPS counter and its
  performance monitor show. The renderer now sees Wine's display and windows ("Opening display",
  "Track … win"). The layer's own FPS counter is now off unless BOTTLE_FPS_COUNTER=1-4 asks for it.
- The tall performance-monitor bar at full detail (~150 px, the frame-time graph) looked right
  after Restart Steam with the layer's own counter gone (19:58, Michael: "looking good").
- The VM can't see the Mac's GPU or temperatures, so the monitor shows GPU 0% and no temperatures.

**A game that quits by itself gets a detailed log next time (Oct 10).** Every launch has a light
log (`~/steam-<appid>.log`: Proton's setup, the DLLs the game loads, Wine's errors). FINAL FANTASY
RESONANCE DEMO (4474710, Unreal Engine, DirectX 12, Denuvo) quit ~3 s after starting: it connected
to Steam and opened an HTTPS connection, then shut down, before loading DirectX 12 (no d3d12.dll,
DXVK's DXGI never set up) and before writing its own Unreal log. The light log can't say why.
- The `user_settings.py` that steam-arm64 writes now also checks the previous launch's log. If that
  launch ended within a minute (first to last Wine timestamp), this launch gets
  `WINEDEBUG=+timestamp,+pid,+tid,+seh,+threadname,+debugstr,+loaddll,+mscoree` (exceptions and the
  program's own debug messages). The next normal-length launch is light again.
- It writes straight into Proton's game environment (`__main__.g_session.env`), because the light
  log's WINEDEBUG is already set and Proton lets that win over user_settings. Only with this
  launcher's light log (BOTTLE_LIGHT_LOG=1); a PROTON_LOG or WINEDEBUG of the user's is left alone.
- `bottle log export` also collects what games write in their Windows prefix (last 3 days): Unreal
  `AppData/Local/<game>/Saved/Logs` and crash folders, Unity `Player.log`, `Documents/My Games`, and
  `Saved/Logs` kept in an install folder (`game-engine-logs/` in the archive).
- `bottle log export` also writes `crash-sites.txt`: for each crash in the newest game logs
  (access violation, illegal instruction, …), the backtrace frames with the code bytes around each
  address, read from the game's own .exe/.dll (PE sections mapped to file offsets), to disassemble.
- Result, second launch (20:16, detailed log): **a crash, not a quit.** EXCEPTION_ACCESS_VIOLATION
  at FFRS-Win64-Shipping.exe+0x11C6C18 reading 0x0067006400690057, which is the UTF-16 text "Widg"
  used as a pointer. The code there is a wide-string length loop (Unreal's FString from a TCHAR*).
  Its caller walks 32-byte entries {register fn, register fn, name, info}, which is Unreal's
  compiled-in class registration during static initialisation, before WinMain. The frame above
  that is in `.didata` and starts with a register-saving stub (pushfq, lock cmpxchg spinlock,
  all registers saved): Denuvo's protected code. So Denuvo's code passed a wrong table or count,
  and the loop read class-name text as a pointer. This came 0.5 s after Denuvo's online
  check (schannel/wininet). The demo is Platinum on ProtonDB (x86 Linux), so this is specific to
  the emulated x86 (FEX) or the VM. Not worked around, and nothing is done to Denuvo itself.
- DirectX 12: see the next section.

**Per-game settings (Oct 10).** `KEY=VALUE` lines in `~/.config/steamos-bottle/games/<appid>.env`
in the VM (yours) or `guest/games/<appid>.env` in the kit (for games the bottle knows need
something) go into that game's environment. The `user_settings.py` steam-arm64 writes applies
them straight into Proton's game environment; yours win over the kit's, and launch options or
steam.env win over both (the launcher's own defaults, BOTTLE_AUTO_VARS, don't). FEX reads its
`FEX_*` options from the environment of every process, so this also sets the x86 emulator per
game. Applied values: `~/.cache/steamos-bottle/game-logs/settings-<appid>.txt` (in the export).
- FINAL FANTASY RESONANCE (demo 4474710, full 3259780): tried FEX at its most exact
  (`FEX_X87REDUCEDPRECISION=0`, `FEX_MULTIBLOCK=0`, `FEX_TSOENABLED=1`, then also
  `FEX_SMCCHECKS=full`, for Denuvo's self-modifying code, FEX issue #2841). The crash stayed the
  same: same address, same "Widg" value, every time. It runs on a Steam Deck (Michael, 22:13), so
  the copy protection most likely turns down the emulated CPU or the VM; the files now hold no
  settings, only these notes. The bottle doesn't hide the VM or the emulator from it.
  Steam's FEX compat tool runs with `X87ReducedPrecision=1` (ConfigTemplate.json) and
  `ProfileStats=1` (the fex-*-stats files in /dev/shm). Nothing is done to Denuvo.

**DirectX 12 (Oct 10, work in progress).** Games' DX12 goes through Proton's vkd3d-proton
(d3d12.dll, d3d12core.dll) and DXGI from DXVK (dxgi.dll, the bottle's 2.6.2).
- What actually stopped it, read from vkd3d-proton 3.0.1's source and the VM's full
  `vulkaninfo` (now in every log export: `vulkaninfo.txt`):
  1. DXGI: Proton's DXVK 3.x dxgi.dll found no adapter (it needs maintenance5/6). bottle-dxvk
     already replaces it with 2.6.2 in game folders and prefixes. vkd3d-proton itself treats
     maintenance5/6 as optional.
  2. vkd3d-proton's hard checks: single-texel buffer view offsets (KosmicKrisp reports 16-byte
     offsets: it makes each texel buffer an MTLTexture on the MTLBuffer at the view's offset, which
     Metal wants aligned), and transform feedback queries (KosmicKrisp has no transform feedback;
     the layer already stands in for DXVK and vkd3d). Everything else it requires is there:
     Vulkan 1.3, vertex attribute divisor, robustness2 with null descriptors, push descriptors,
     shaderDrawParameters, samplerMirrorClampToEdge, mutable descriptors, 1M descriptors per set.
  3. Feature level: no sparse memory, so no tiled resources, so feature level 11_1 at most.
     Many DX12 games ask for 12_0 to start.
  Older vkd3d-proton versions don't help: the two hard checks have been there since 2.10, and
  2.8 needs Vulkan 1.1 only but is too old for current games.
- What the bottle does now:
  - The layer reports single-texel offsets as supported to vkd3d instances on managed devices,
    and hides VK_EXT_descriptor_buffer from them. Without descriptor buffers vkd3d-proton
    always uses its "typed offset buffer" (state.c): each typed view starts at the start of its
    resource (quantized by maxTexelBufferElements, 2^28 here) and the shader adds the element
    offset, so the views it creates stay aligned. The layer logs any typed view whose offset
    isn't a multiple of 16 ("DirectX 12: typed buffer view at offset …").
  - It also stands in for stream-output statistics query pools (an occlusion pool, so
    begin/end/copy stay valid), strips VK_KHR_present_id2/present_wait2, present timing, FIFO
    latest-ready and swapchain_maintenance1 (Venus lists the first two, and vkd3d-proton 3.x
    would use them on the CPU-copy swapchain), and `steam-arm64` sets `VKD3D_FEATURE_LEVEL=12_0`
    (vkd3d-proton's own setting; steam.env or launch options win).
- Tested here with vkd3d-proton 3.0.1's own test suite (544 tests, `tests/d3d12`, built for
  Linux) on lavapipe, once as is and once through the layer with `BOTTLE_TEST_TEXEL_ALIGN=16`
  (lavapipe then reports what Venus reports: 16-byte texel offsets, no descriptor buffers).
  Unaligned views came only from test_large_texel_buffer_view (views at the end of a buffer
  bigger than maxTexelBufferElements) and test_uav_clear_exhaustive_descriptors (a UAV clear at an
  odd offset; that test crashes on lavapipe either way). Results, without / with the layer:
  23,085,698 / 23,084,128 checks, 9,362 failed checks both times (lavapipe's own gaps), the same
  tests timing out or crashing (fence stress tests and lavapipe memory stress), apart from
  test_execute_indirect_state_predication, which passed in 58 s alone with the layer (it ran out of
  its 90 s while both runs shared 2 CPUs).
- On the Mac: `bottle selftest dx12-venus` runs a set of those tests on Venus through FEX, the
  way games reach the GPU (`guest/tests/dx12-venus.sh`, binaries in `guest/tests/dx12-venus/`).
  `bottle selftest dmc5-dx12` / `dmc5-dx11` switch Devil May Cry 5's API in dmc5config.ini.
- **On the Mac (22:16, Venus through FEX): DirectX 12 works.** test_create_device, clears, draws,
  UAVs, descriptor tables, root constants, DXIL shaders, typed buffers, buffer SRVs, UAV clears: 21
  of 22 test groups passed with no failed checks (test_sample_instructions: 31 of 1850 checks
  failed, in one sub-test). Each group ran in about a second.
- **Then test_large_texel_buffer_view stopped the whole VM (22:17:11):** krunkit aborted on Metal's
  always-on check, "MTLTextureDescriptor has width (536870912) greater than the maximum allowed size
  of 268435456". vkd3d-proton passes D3D12 typed views wider than maxTexelBufferElements on to
  Vulkan (invalid, but most drivers let it pass); KosmicKrisp makes a Metal texture buffer that wide.
  The layer now cuts any typed view on a managed device to maxTexelBufferElements (a VK_WHOLE_SIZE
  view is measured from the buffer's memory requirements); beyond that it reads as out of bounds.
  Tested on lavapipe: the large-view test logs the cuts and fails its far-end checks instead of
  crashing; buffer SRV/UAV/clear tests unchanged. The test and those of features the Mac's GPU
  lacks are out of dx12-venus's default list.
- Also found: the background watcher died at 21:52 when it restarted into a bottle copy that had
  just landed without its execute bit ("Permission denied"). It now restarts through `bash`, only
  into a copy that passes `bash -n`, 2 s after the change; awake_start restarts one that hasn't
  gone round for 5 minutes (awake.beat); the Mac log export shows the watcher's log.
- **Proton Experimental now ships vkd3d-proton 3.1.0, which requires maintenance5/6** (The Witcher
  3 5.0, 23:41: "maintenance5 and/or maintenance6 not supported by this implementation. This is
  required for correct operation", then the game's "Support for DirectX 12 is required"). 3.0.1
  doesn't, and is what ran on Venus above. `update-guest.sh` fetches the vkd3d-proton 3.0.1
  release (sha256 3cf23155…, zstd) into /usr/local/share/steamos-bottle/vkd3d-proton-3.0.1, and
  `bottle-dxvk` puts its d3d12.dll and d3d12core.dll into every Proton
  (files/lib/wine/vkd3d-proton/{x86_64,i386}-windows, originals as .bottle-orig) and every game's
  prefix (system32/syswow64; Wine's builtin d3d12 left alone), on the same passes as DXVK;
  `bottle-dxvk remove` puts Proton's back. Tested on a fake library (apply, second pass, remove).
- Devil May Cry 5 (DX12 test): Michael couldn't run it; it was uninstalled at 23:19.
- **00:19, Oct 11: The Witcher 3 5.0 runs in DirectX 12** (vkd3d-proton 3.0.1 in place), ~43 fps
  in White Orchard. A first dark area was Steam's performance monitor at full detail (fine after a
  restart). A second one, a stepped dark rectangle that stays put on screen: vkd3d-proton refused
  six compute shaders ("Attempting to use 16-bit operations in shader …, but this is not
  supported"): native 16-bit shaders need shaderDenormPreserveFloat16 and a
  denormBehaviorIndependence other than NONE, and KosmicKrisp reports neither. The layer now
  reports both to vkd3d instances on managed devices (logged once). On lavapipe, made to report
  what KosmicKrisp does, test_shader_fp16 then runs all 48 checks (one sub-test skipped before)
  with no failures.
- `bottle selftest NAME` (new): copies `guest/tests` into the VM and runs `NAME.sh` there, output
  in `logs/selftest-NAME-<time>.txt`. A file `logs/.selftest` holding the name starts it from the
  background watcher, not while a game runs.

**Quitting the app.** While the VM is on screen, ⌘Q and ⌘W ask first (⌘ sits where Alt is on a
PC keyboard): Keep Playing, Quit (Steam and games keep running in the VM; open the app to get back),
or Quit and Shut Down the VM. ⌘Esc frees the mouse.

**What's still missing:** geometry shaders (KosmicKrisp is getting them; until then
games that use them misrender), and GPU OpenGL for native Linux games.

Reports from `bottle-bench` and setup land in `/tmp/lima/steamos-bottle-results/` on the Mac.

## First run results (M4 Max, 36 GB, macOS 26.6, Lima 2.2.1, krunkit 1.3.2, Fedora 44 guest)

| Check | Result |
|---|---|
| VM create / first boot / provision | 192 s / 38 s / 177 s |
| GPU in guest | ✅ `Virtio-GPU Venus (Apple M4 Max)`, Mesa 25.3.6, **Vulkan 1.2** |
| DXVK requirements on Venus | ❌ `geometryShader`, `nullDescriptor`, `robustBufferAccess2`, `shaderFloat64`, `synchronization2` missing |
| Vulkan presentation | ❌ no `VK_KHR_swapchain` on Venus (no dma-buf on a macOS host) → vkcube can't open |
| OpenGL in guest | software only (llvmpipe); zink fails (needs the swapchain) |
| FEX | ✅ x86 + x86_64 via binfmt, ~2.2–2.5× slower than native on a shell loop |
| ARM64 Steam client | ✅ starts in ~2 s, logs in, library loads, CEF UI fine in software |
| Windows game (Abathor) | ✅ **reaches its title screen** via x86_64 Proton Experimental under FEX with `PROTON_USE_WINED3D=1`; ❌ not playable: x86 llvmpipe runs under FEX (`256 bits`), so frames take seconds and input looks dead |

Fixes the first run needed (all now automated in the scripts): Lima tap moved to
`libkrun/krun` + Homebrew tap trust; Steam runtime layout changed (libs found by
search, Fedora gtk2/ibus fallback); Fedora's CA bundle linked to the Debian paths
Steam expects; `systemd-binfmt` start-limit reset; `umask` leak in the desktop
script; Steam's FEX wants an x86 rootfs at `/usr/share/guestos/fex-mesa`; FEX socket
paths must stay under 107 chars (VM user is now `deck`, home `/home/deck`); the
`~/.steam/{sdk32,sdk64,bin32,bin64,root}` links Proton needs.

**Update, present layer (`guest/present-layer`):** a Vulkan layer that gives Venus a
CPU-copy X11 swapchain. vkcube now renders on the GPU and shows on screen at
~2,000 fps (500×500). Zink (OpenGL over Vulkan) still refuses Venus:
"Zink requires the nullDescriptor feature of KHR/EXT robustness2", the same
MoltenVK gap that blocks DXVK. Next experiment: run krunkit's virglrenderer on
**KosmicKrisp** (LunarG's conformant Vulkan-on-Metal driver, macOS 26+, Apple
Silicon) instead of MoltenVK, which reportedly has nullDescriptor/robustness2.

**Update, KosmicKrisp + x86 GPU path:** with `host/kosmickrisp.sh enable` Venus reports
Vulkan 1.3 with `nullDescriptor`/`robustBufferAccess2`, and zink (GL on Venus) works.
FEX thunks crash inside Wine's startup, so the x86 side gets its own GPU driver instead:
`guest/x86-venus.sh` copies the Mac-patched Venus driver (COPR `slp/mesa-libkrun-vulkan`,
x86_64 build: 16K-aligned buffers, no dma-buf device filter) into the FEX rootfs. Stock
Fedora Mesa fails there with `vkCreateInstance: -1`. Proton's DXVK then finds
`Virtio-GPU Venus (Apple M4 Max)` but rejects it for missing `fillModeNonSolid` (and
`geometryShader`), so the layer now reports those as supported to DXVK/vkd3d instances
and strips them in `vkCreateDevice` (`BOTTLE_FAKE_FEATURES=0` turns that off).
DXVK 3.x (Proton's) also needs `VK_KHR_maintenance5/6`, which this GPU lacks, so Abathor
runs DXVK 2.6.2 dropped into its game folder (`d3d11.dll`, `dxgi.dll`). 2.6.2 requires
`VK_EXT_transform_feedback`: the layer advertises a no-op stand-in to DXVK (stream output
is ignored) and maps `VK_KHR_load_store_op_none` to the `EXT` version the GPU has.

**Update, 32-bit games (Oct 14):** Blades of Time (GOG, 32-bit) first died on its first GPU
buffer, then showed a white window. Three separate causes, none of them GOG's:
1. The 32-bit Vulkan driver in the x86 system (`usr/lib` of `/usr/share/guestos/fex-mesa`) was stock
   Mesa, without the 16K alignment a Mac host needs: `mmap failed ... Invalid argument`, then Venus
   aborts the game. The COPR has no 32-bit build, so `guest/x86-venus/` carries one built from the same
   Mesa 25.3.6 and the same three patches (`build-i686.sh`; `x86-venus.sh` installs it, stock copy kept
   as `.stock`, and sets the 32-bit ICD's `api_version` to 1.4.328).
2. The bottle's layer only existed as x86_64 and arm64 builds. A 32-bit game saw the raw GPU, so DXVK
   asked for `geometryShader`/`fillModeNonSolid`, which Venus lacks, and `vkCreateDevice` failed with
   `VK_ERROR_FEATURE_NOT_PRESENT` (and nothing would have presented a frame anyway).
   `present-layer/i386/` is the 32-bit build (`build-i386.sh`), installed as
   `usr/lib/libVkLayer_bottle_present.so` with its own manifest and layer name
   (`VK_LAYER_BOTTLE_cpu_present_i686`): the loader keeps one layer per name, and the x86_64 manifest's
   library can't load in a 32-bit process.
3. The Oct 13 Proton update left read-only `.bottle-orig` files; `bottle-dxvk` then failed halfway and
   the DXVK 2.6.2 drop-in was gone from all Proton games. It keeps going now, file by file.
Tried and dropped: `PROTON_USE_WOW64=1` (32-bit games on the 64-bit side): Wine's new WoW64 mode doesn't
start under FEX ("Failed to create process", error 731). `guest/tests/vk32-probe.c` is a 32-bit Vulkan
program for checking the 32-bit side without a game (run under FEX with `FEX_ROOTFS`; `dxvk` as the
argument tries each extension and feature set DXVK uses; `VK32_ENGINE=DXVK` makes the layer apply its
stand-ins); `install-x86.sh` runs it after installing.

**Update, first playable run:** Abathor runs at a steady 60 fps at 1920x1080 on the GPU
(DXVK 2.6.2 → Venus → KosmicKrisp → Metal; frames shown by the layer). Two desktop
fixes came out of it: the desktop now uses TigerVNC `Xvnc` (whole frames, so no tearing;
prompt input; full keyboard map) instead of Xvfb + x11vnc, which scraped the screen in
strips, tore at 60 fps, and delivered key presses late. Next: show frames in a native Mac
window instead of VNC.


## Checklist

Each stage is a go/no-go gate. If a stage fails, note what you saw and stop:
the later stages depend on it.

### Stage 1: The VM boots with a GPU
- [ ] `setup-host.sh` finishes without errors
- [ ] Host report shows `create`, `boot` and `provision` times → **record boot time**
- [ ] Guest summary shows a `/dev/dri/renderD*` node and page size `4096`

*Means for the app:* boot time is the bottle's cold-start cost. Under ~10 s is fine to hide behind a launch screen.

### Stage 2: Venus is real, and does it have what DXVK needs?
From `bottle-bench`:
- [ ] Vulkan device says **Venus** (not llvmpipe) → record `deviceName`, `apiVersion`
- [ ] Record the feature list, especially: `geometryShader`, `tessellationShader`,
      `VK_EXT_robustness2` / `nullDescriptor`, `VK_EXT_transform_feedback`,
      `depthClipEnable`, `descriptorIndexing`, `bufferDeviceAddress`, sparse features
- [ ] vkmark score → **record**

**This is the most important gate.** MoltenVK has not supported geometry shaders (Metal has no geometry stage),
and Venus can only pass through what MoltenVK exposes. If `geometryShader = false`:
- DXVK (D3D9/10/11) games will mostly fail to start or render incorrectly
- VKD3D-Proton (D3D12) is very unlikely to work
- ARM64-native and Vulkan-native Linux games can still work → the bottle would be
  a "Linux/Steam Frame games" feature, not a Windows-games replacement for Wine

### Stage 3: FEX runs x86 code
- [ ] `FEXBash uname -m: x86_64` → PASS
- [ ] Record the shell-loop ratio (FEX/native). Under ~3× is good for game logic;
      a much higher ratio suggests FEX is emulating memory ordering (TSO) in software
- [ ] Record what the x86 side sees for Vulkan (thunks are off on purpose)

### Stage 4: Desktop over VNC
- [ ] `connect-vnc.sh` opens Screen Sharing and shows an xterm
- [ ] `bottle-bench` in that xterm shows a GL renderer. Note both the default and
      the zink line. If the default is `llvmpipe` but zink shows Venus, GL games
      need `MESA_LOADER_DRIVER_OVERRIDE=zink`

### Stage 5: ARM64 Steam client
- [ ] `steam-arm64` downloads, updates and shows the login window → **record time
      to login window** (first run and second run)
- [ ] Log in; library loads
- [ ] Settings → Compatibility: an **ARM64 Proton** entry is available
- [ ] Settings → In Game → enable the in-game FPS counter

### Stage 6: Games (one per path, light titles first)
For each, record: starts? (y/n), FPS at a fixed spot, resolution, glitches, crash text.

| Path | Pick | Starts | FPS | Notes |
|---|---|---|---|---|
| ARM64-native / "Great on Frame" title | | | | |
| x86 Linux native (via FEX) | | | | |
| Windows D3D9 game (Proton ARM64) | | | | |
| Windows D3D11 game (Proton ARM64) | | | | |
| Same D3D11 game in your Wine/CrossOver setup (baseline) | | | | |

The last row is the comparison that matters: the bottle must be competitive with
the Wine path on at least one category of games to justify the app.

### Stage 7: Does it behave like a bottle?
- [ ] Stopped-VM clone: `limactl stop steamos-bottle && time limactl clone steamos-bottle bottle-2`
      → **record time and disk use** (`du -sh ~/.lima/bottle-2`)
- [ ] Idle cost with Steam open: Activity Monitor CPU % and memory of the krunkit process

## Results to send back

The two report files (`host-*.txt`, `guest-*.txt`), the filled-in Stage 6 table,
and any crash text. That's enough to decide whether to build the bottle manager,
and what the first version should support.

## Troubleshooting

**"The VM's screen server doesn't start" after a shutdown.** Lima stops the krunkit VM in under
a second, without the VM writing out what it still held in memory, so programs an update had just
installed could come back empty (Oct 8: bottle-screen). `bottle stop` now has the VM save
everything first (`vm_stop`: `sync`, then `limactl stop`), the update ends with `sync`, and
starting the bottle (`bottle _up`, also from the app) checks the kit's programs in the VM and
reinstalls them with `bottle update` when one is empty or all zeros.

**krunkit driver missing.** `limactl info | jq .vmTypesEx` should list `krunkit`.
If not, build the driver (from Lima's docs): clone `lima-vm/lima`, check out your
Lima version tag, `make ADDITIONAL_DRIVERS=krunkit additional-drivers`, then copy
`_output/libexec/lima/lima-driver-krunkit` into `$(brew --prefix)/libexec/lima/`.

**COPR has no Mesa build for this Fedora.** The Lima `template:fedora` may have
moved to a Fedora release the `slp/mesa-libkrun-vulkan` COPR doesn't build for yet.
Delete the VM and create it from an older Fedora image, or check the COPR page for
supported releases.

**Don't run `dnf upgrade` in the VM** unless the versionlock was applied; it can
replace the Venus-patched Mesa with stock Mesa (you'll see llvmpipe again).

**Steam window is blank or black.** Quit and start it with
`steam-arm64 -cef-disable-gpu-compositing` (or `-cef-disable-gpu`).

**Steam can't find the ARM64 client in the manifest.** Valve changes the beta
channel layout from time to time. Check
<https://github.com/justradical/steam-arm64-fedora> for an updated launcher.

**A game's picture freezes, its sound goes on.** `bottle log export` while it's frozen: the
export lists what each of the game's threads is waiting in, and the game's log marks when frames
stopped ("no new frame from the game") and came back, with the time of day.

**Start over:** `limactl delete -f steamos-bottle`

## Credits

- Lima krunkit driver and the Venus Mesa recipe: <https://lima-vm.io/docs/config/vmtype/krunkit/>
- `steam-arm64` is adapted from ROCKNIX's script as modified in
  <https://github.com/justradical/steam-arm64-fedora> (GPL-2.0-or-later)
