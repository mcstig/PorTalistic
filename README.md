<p align="center"><img src="host/AppIcon.png" alt="" width="128"></p>

# Portalistic

Steam on an Apple Silicon Mac. Portalistic runs Valve's Steam client in a small Linux system on
your Mac, drawing with the Mac's GPU, and Steam plays Windows games through Proton.

**[Download the latest version](https://github.com/mcstig/PorTalistic/releases/latest)**

## What you need

- An Apple Silicon Mac with macOS 26 or newer and 8 GB of memory or more. The Linux system gets
  its share (4 GB on an 8 GB Mac, 8 GB on a 16 GB one); bigger games want a Mac with 16 GB.
- A few GB of disk for the Linux system, plus your games.

## Getting started

1. Unzip the download and open Portalistic. Outside Applications it offers to move itself there.
2. The first launch downloads its Linux system (a little over 2 GB). Steam then installs itself
   and asks you to sign in.
3. Install a game from Steam as usual. Windows games run through Proton; the first start of a
   game takes a few minutes while Proton prepares it (the window says so).

Portalistic updates itself: it offers each new version when it opens.

## Where games go

Games go in `Games/Portalistic` in your home folder. **Game Folders > Add a Game Folder…** adds
another folder or an external drive (Portalistic offers a drive when you connect it). Inside each
game folder, games live in a file called `Portalistic Games.img`, a drive the Linux system reads
directly; it takes only as much space as the games in it.

## GOG and Epic games

**Stores > GOG Games…** and **Stores > Epic Games…** sign in to your GOG or Epic account, list
the games you own that have a Windows version, and install the one you pick into a game folder.
Installed games appear in Steam's library (collections "GOG" and "Epic Games") and run through
Proton like the rest.

## The window

- Steam fills the window (Big Picture). ⌃⌘F is full screen.
- When a game captures the mouse, ⌘Esc frees it; a click captures it again.
- Game controllers connected to the Mac (Bluetooth or USB) work in games as Xbox controllers.
- **Steam > Switch to Desktop Mode…** gives you a Linux desktop, like the Steam Deck's;
  **Switch to Game Mode** goes back. Its file manager reaches the file servers on your network
  (Network, in its sidebar).
- **Steam > Restart Steam**, **Update the VM** and **Shut Down the VM** do what they say;
  **Save Logs** writes a file to send with a bug report.

## What won't work

- Games whose anti-cheat doesn't accept Proton or a virtual machine, and some whose copy
  protection fails under x86 emulation. Portalistic doesn't work around either.
- Native Mac games aren't used: Portalistic runs Steam's Linux client, so a game plays as its
  Windows (or Linux) version.
- It's experimental: the ARM64 Steam client it uses is a beta build from Valve. Expect rough edges.

## If something goes wrong

- A black window for a long time: choose **Steam > Restart Steam**.
- A game that quits at once says why in the window when Portalistic can tell.
- Report a problem at [Issues](https://github.com/mcstig/PorTalistic/issues) with the file from
  **Steam > Save Logs**.

## Removing Portalistic

**Portalistic > Uninstall Portalistic…** deletes the Linux system and Portalistic's files and
moves the app to the Trash; your game folders stay unless you tick the box. Install Portalistic
again later and the games in them are back, GOG and Epic ones included.

## Support, license, credits

Portalistic is free. If you'd like to support it: [Patreon](https://www.patreon.com/PorTalistic).

Portalistic isn't affiliated with Valve. It's free software under the GNU GPL, version 3
([LICENSE.md](LICENSE.md)); the software it includes and their licenses are in
[LICENSES.md](LICENSES.md). It builds on Lima and krunkit (libkrun), Fedora, Mesa's Venus and
KosmicKrisp, FEX, Proton, DXVK and vkd3d-proton, Heroic's gogdl and Legendary.

How it's built, the `bottle` command and the development log: [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).
