# Portalistic: third-party software and licenses

Portalistic's own code (the app, the `bottle` command, and the scripts and programs it puts in
the Linux VM) is free software under the GNU General Public License, version 3: LICENSE.md, and
the source at https://github.com/mcstig/PorTalistic.

Portalistic is not affiliated with or endorsed by Valve or GOG. Steam and SteamOS are trademarks of
Valve Corporation; GOG is a trademark of GOG sp. z o.o. Portalistic doesn't include Steam or Proton: the Linux system it sets up
downloads Valve's Steam client from Valve, and Steam downloads Proton and its runtimes itself,
under Valve's terms (the Steam Subscriber Agreement).

## In Portalistic.app

| Component | What it does | License | Source |
|---|---|---|---|
| Lima (`limactl`, `lima-driver-krunkit`, guest agent) | Creates and runs the Linux VM | Apache-2.0 | https://github.com/lima-vm/lima |
| krunkit | The VM process | Apache-2.0 | https://github.com/containers/krunkit |
| libkrun | The virtual machine monitor krunkit uses | Apache-2.0 | https://github.com/containers/libkrun |
| libkrunfw | The VM's Linux kernel, as a library | GPL-2.0-only (Linux kernel), LGPL-2.1-only | https://github.com/containers/libkrunfw (see "Corresponding source" below) |
| `KRUN_EFI.silent.fd` | The EFI firmware the VM boots with (EDK II) | BSD-2-Clause-Patent | https://github.com/containers/krunkit, https://github.com/tianocore/edk2 |
| virglrenderer (krunkit branch) | The VM's GPU (Venus) on the Mac side | MIT | https://gitlab.freedesktop.org/slp/virglrenderer |
| libepoxy | OpenGL function loading for virglrenderer | MIT | https://github.com/anholt/libepoxy |
| Vulkan Loader | Loads the Vulkan driver | Apache-2.0 | https://github.com/KhronosGroup/Vulkan-Loader |
| KosmicKrisp (Mesa, as shipped in the LunarG Vulkan SDK) | Vulkan on Metal | MIT | https://gitlab.freedesktop.org/mesa/mesa |

## In Portalistic's Linux image

A Fedora Linux 44 (aarch64) Cloud system with the packages Portalistic needs. The full list of
packages with their versions and licenses is published next to each image
(`portalistic-linux-<version>.packages.txt`). Notable parts:

| Component | License | Source |
|---|---|---|
| Fedora Linux packages (kernel, systemd, TigerVNC, PipeWire, Mesa…) | Each package's own (GPL, LGPL, MIT, …) | Fedora's source RPMs for the exact versions: https://koji.fedoraproject.org |
| Mesa with Venus for krunkit (COPR `slp/mesa-libkrun-vulkan`, aarch64 and x86_64) | MIT | https://copr.fedorainfracloud.org/coprs/slp/mesa-libkrun-vulkan/ |
| Mesa 25.3.6 Venus driver, 32-bit x86 build with the COPR's three patches (`guest/x86-venus/`: the library, the patches and the build script) | MIT | https://gitlab.freedesktop.org/mesa/mesa, patches from https://copr.fedorainfracloud.org/coprs/slp/mesa-libkrun-vulkan/ |
| FEX-Emu and its Fedora x86_64 system | MIT (FEX); the x86 system: Fedora packages' own | https://github.com/FEX-Emu/FEX |
| DXVK 2.6.2 | Zlib | https://github.com/doitsujin/dxvk |
| dxvk-gplasync 2.6.2-1 | Zlib | https://gitlab.com/Ph42oN/dxvk-gplasync |
| vkd3d-proton 3.0.1 | LGPL-2.1-or-later | https://github.com/HansKristian-Work/vkd3d-proton/tree/v3.0.1 |
| gogdl 1.3.1 (Heroic Games Launcher's GOG downloader), with one small change (`guest/stores/MODIFICATIONS.txt`) | GPL-3.0-or-later | https://github.com/Heroic-Games-Launcher/heroic-gogdl |
| xdelta 3.0.12 (inside gogdl's patch module) | Apache-2.0 | https://github.com/jmacd/xdelta |
| Legendary 0.21.1 (the Epic Games Store downloader, `legendary-gl`), with one small change (`guest/stores/MODIFICATIONS.txt`); the VM also installs Fedora's `python3-filelock` and `python3-pycryptodomex` for it | GPL-3.0-or-later | https://github.com/legendary-gl/legendary |
| Comet 0.3.2, the open-source stand-in for the GOG Galaxy client's background service, built from its source unchanged (`guest/comet/`: BUILT, CRATES.tsv, THIRD-PARTY-LICENSES.txt list and reproduce the 251 Rust packages compiled into it, all under MIT, Apache-2.0, BSD, ISC, Zlib, Unicode, 0BSD, Unlicense or BSL-1.0) | Apache-2.0 (its protocol definitions: CC0-1.0) | https://github.com/imLinguin/comet |
| KDE Plasma 6 (X11 session), Dolphin, Konsole, Kate, Spectacle, Discover, Flatpak, Firefox and their dependencies: not in the image; the VM downloads them from Fedora's repositories when Desktop Mode is first switched on (`guest/bottle-session`) | Each package's own (GPL, LGPL, MIT, MPL-2.0, …) | Fedora's source RPMs: https://koji.fedoraproject.org |
| Portalistic's own programs in the VM (`guest/` in the source) | GPL-3.0 | https://github.com/mcstig/PorTalistic |

## Corresponding source

For the GPL and LGPL software in the app and the image (the Linux kernel in libkrunfw, Fedora's
packages, vkd3d-proton), the exact source is available:

- **libkrunfw** (the kernel the VM runs): the release's source and the Linux kernel source it
  builds from are published with each Portalistic release
  (`libkrunfw-<version>-source.tar.gz`, `linux-<version>.tar.xz`), and at the links above.
- **Fedora packages in the image**: Fedora's source RPMs for the versions listed in the image's
  packages list (https://koji.fedoraproject.org keeps every build).
- On request, for three years after a release, the maintainer of Portalistic provides the
  complete corresponding source of any GPL or LGPL component Portalistic distributes, for no more
  than the cost of providing it. Ask on the project's GitHub page.

Each component's full license text is in its source; the Fedora packages' are in the image under
`/usr/share/licenses`.
