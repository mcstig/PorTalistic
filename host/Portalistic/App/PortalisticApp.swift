// Portalistic: the Mac window of the SteamOS bottle.
//
// Shows the VM's desktop (Steam and its games) and sends keyboard and mouse back. The VM side
// is guest/screen/bottle-screen.c: JPEG frames out, input in, over TCP 127.0.0.1:4720 (Lima
// forwards the port). Frames are the whole screen or just the part that changed, drawn into
// one picture (Framebuffer); once the screen is still, a sharp copy (quality 95, full colour
// detail) follows. The picture is shown with Metal: MetalFX enlarges it to the window's pixel
// size, in step with the display, at up to 120 fps on ProMotion screens (View menu). When a
// game hides its pointer (mouse-look), the app captures the Mac's mouse and sends raw relative
// motion, which VNC can't do. Command-Escape releases the mouse; a click in the window lets it
// capture again. Command shortcuts stay with the Mac. Game controllers (Xbox, PlayStation
// DualSense/DualShock, other MFi pads) become virtual Xbox 360 pads in the VM, and the game's
// rumble comes back to them.
//
// Opening the app starts whatever isn't running (the VM, Steam, the sound: `bottle _up`) and
// shows its progress; the Steam menu runs the kit's other commands (restart Steam, update,
// logs, shut down). What the window shows is Steam in Big Picture, as on SteamOS: the VM starts
// Steam that way and keeps it there (guest/bottle-maximize-steam; `bottle ui desktop` switches to
// Steam's desktop windows). When the kit has newer code than the running build, the app
// rebuilds itself. (An earlier home screen of its own, the Library, is in host/archive/.)
//
// The code, in host/Portalistic/ (Xcode's project includes the whole folder):
//   App/       this entry point; AppDelegate and its extensions (starting the bottle, menus,
//              picture settings, quitting)
//   Stream/    the screen protocol, the connection to the VM, the picture it builds
//   Display/   the Metal renderer and the view that shows the VM and takes input
//   Input/     game controllers, rumble, the keyboard map
//   Bottle/    running the kit's bottle command, the starting screen, the Activity window
//
// Built into ~/Applications/Portalistic.app by `bottle window` or the app's self-update:
// with Xcode (host/Portalistic.xcodeproj, signed with your team; `bottle xcode` sets it up),
// else with swiftc. Info.plist says where the kit is (BottleKitDir) and the PATH to run it
// with (BottlePath).

import AppKit

/// The entry point (an @main type, so the code can live in many files: Xcode and
/// `swiftc -parse-as-library` both start here).
@main
@MainActor
enum PortalisticApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate                  // a weak reference: kept alive below
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}
