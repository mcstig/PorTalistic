// Portalistic — full screen without the Mac's menu bar, which slides back at the top edge.

import AppKit
import os

/// In full screen macOS hides the menu bar and brings it back (with the window's title bar and its
/// full-screen button) when the pointer reaches the top edge, unless System Settings says
/// "Automatically hide and show the menu bar: Never". Then the menu bar stays, and nothing an app
/// asks for changes that (Nov 2, Michael's Mac: presentation options and NSMenu.setMenuBarVisible
/// both left the menu bar's window on the screen). So Portalistic covers it: a black strip above the
/// menu bar, as tall as the gap macOS leaves between the screen's top and the window. When the
/// pointer rests at the top the strip fades out, which shows the menu bar, and macOS brings the title
/// bar down as usual; lower down again, or off this screen (and no menu open), it fades back in. Whichever
/// app is in front: macOS shows that app's menu bar here then (until Nov 3 the strip lifted only with
/// Portalistic in front, and the menu bar that came down stayed black until a click).
///
/// Nov 3: the strip follows the window's real state every tick, not only macOS's enter/exit
/// notifications: after leaving full screen it had stayed on the desktop (black, at times halfway
/// down the screen, where macOS had moved it), and on the next full screen it was still there, not
/// over the menu bar. And the pointer has to rest at the top a moment: on Michael's Mac the DELL sits
/// above the built-in screen, and passing up to it showed the menu bar for an instant every time (at the
/// top edge where no screen is above, it shows at once).
final class MenuBarCover {
    private var strip: NSPanel?
    private var timer: Timer?
    private weak var window: NSWindow?
    private var revealed = false
    private var atTopSince: Date?
    private let log = Logger(subsystem: "Portalistic", category: "menubar")

    private static let rest: TimeInterval = 0.25     // how long the pointer rests at the top to show the menu bar

    // (A menu of the menu bar is open while one of its items is highlighted. Until Nov 3 a count of
    // NSMenu's begin/end tracking notifications said so; it got stuck above 0, and the menu bar then
    // stayed in sight for good.)
    private var menuOpen: Bool { NSApp.mainMenu?.highlightedItem != nil }

    deinit { stop() }

    /// The window just went full screen.
    func start(for w: NSWindow) {
        window = w
        revealed = false
        atTopSince = nil
        strip?.alphaValue = 1
        timer?.invalidate()
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.follow() }
        RunLoop.main.add(t, forMode: .common)       // (also while a menu is open)
        timer = t
        log.notice("menubar: full screen, covering")
        follow()
    }

    /// The window leaves full screen (or goes away).
    func stop() {
        timer?.invalidate()
        timer = nil
        strip?.orderOut(nil)
        revealed = false
        atTopSince = nil
    }

    private func makeStrip() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // above the menu bar and its icons (+2: AppKit's own full-screen window over the menu bar is at +1)
        p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 2)
        p.backgroundColor = .black
        p.isOpaque = true
        p.hasShadow = false
        p.ignoresMouseEvents = true              // (the pointer still reaches the menu bar under it)
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.animationBehavior = .none
        p.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle, .moveToActiveSpace]
        return p
    }

    private func follow() {
        guard let w = window else { stop(); return }
        guard w.styleMask.contains(.fullScreen), w.isVisible else {
            log.notice("menubar: not full screen any more, strip off")
            stop(); return
        }
        // in full screen but that space isn't the one shown (another space, or the transition): no strip
        guard w.isOnActiveSpace, let screen = w.screen else { strip?.orderOut(nil); return }
        let gap = screen.frame.maxY - w.frame.maxY   // (the menu bar's height, or the camera's strip)
        guard gap > 1 else { strip?.orderOut(nil); return }   // (the menu bar hides by itself)

        let p = strip ?? makeStrip()
        strip = p
        let rect = NSRect(x: screen.frame.minX, y: w.frame.maxY, width: screen.frame.width, height: gap)
        if p.frame != rect { p.setFrame(rect, display: false) }
        if !p.isVisible { p.alphaValue = revealed ? 0 : 1; p.orderFrontRegardless() }

        let m = NSEvent.mouseLocation
        let onScreen = m.x >= screen.frame.minX && m.x < screen.frame.maxX && m.y >= screen.frame.minY && m.y <= screen.frame.maxY
        let inMenuBar = onScreen && m.y >= w.frame.maxY - 1
        if !revealed {
            if inMenuBar {
                if atTopSince == nil { atTopSince = Date() }
                // at the top edge with no screen above it there: at once; elsewhere in the menu bar, after a rest
                let atEdge = m.y >= screen.frame.maxY - 2 && !Self.screenAbove(screen, x: m.x)
                if atEdge || Date().timeIntervalSince(atTopSince!) >= Self.rest {
                    fade(p, to: 0); revealed = true; atTopSince = nil
                    log.notice("menubar: shown")
                }
            } else { atTopSince = nil }
        } else if !menuOpen && (!onScreen || m.y < w.frame.maxY - 44) {   // (below the title bar that came down)
            fade(p, to: 1); revealed = false
            log.notice("menubar: covered")
        }
    }

    /// Another screen touching this one's top edge at x (the pointer goes on up into it there).
    private static func screenAbove(_ screen: NSScreen, x: CGFloat) -> Bool {
        NSScreen.screens.contains { $0 != screen && abs($0.frame.minY - screen.frame.maxY) < 1 && x >= $0.frame.minX && x < $0.frame.maxX }
    }

    private func fade(_ p: NSPanel, to alpha: CGFloat) {
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.18
            p.animator().alphaValue = alpha
        }
    }
}
