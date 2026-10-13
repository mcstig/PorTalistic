// Portalistic — the VM screen's size follows the window (View > Screen Size).
//
// The VM's screen used to be 1920x1080 whatever the window: a window of another shape (a
// MacBook's 16:10 display in full screen) had black bars, and the picture was enlarged a lot.
// Now the window asks the VM's screen server for a screen of its own shape (RESIZE): as many
// pixels as a 1080p screen ("Like the Window"), or about 2560x1600's worth ("Sharper", more
// detail, more work for the VM and the Mac), never more than the window shows. The screen
// server makes it so with xrandr while no game runs. When a game starts it switches to the
// game size first ("Games at 1920 × 1080", the default: what games here were tested with, so a
// game set to 1920x1080 gets exactly that) or keeps the window's size ("Games at the Window's
// Size"). "Fixed 1920 × 1080" is the old behaviour: the window keeps the picture's shape.
// A screen server from before version 2 doesn't know RESIZE: the window then works as before.

import AppKit

enum ScreenSizeMode: String {
    case window, sharp, fixed

    var title: String {
        switch self {
        case .window: return "Like the Window"
        case .sharp: return "Like the Window, Sharper"
        case .fixed: return "Fixed 1920 × 1080"
        }
    }

    /// The most pixels the VM screen gets (it's never more than the window shows either).
    var pixels: CGFloat {
        switch self {
        case .window, .fixed: return 1920 * 1080
        case .sharp: return 2560 * 1600
        }
    }
}

extension AppDelegate {
    var screenSizeKey: String { "ScreenSize" }
    var gamesFixedKey: String { "GamesAt1080p" }

    var screenSizeMode: ScreenSizeMode {
        ScreenSizeMode(rawValue: UserDefaults.standard.string(forKey: screenSizeKey) ?? "") ?? .window
    }

    var gamesAt1080p: Bool { UserDefaults.standard.object(forKey: gamesFixedKey) as? Bool ?? true }

    /// The screen follows the window: a follow mode, and a screen server that can.
    var followsWindow: Bool { screenSizeMode != .fixed && conn.serverVersion >= 2 }

    /// The window's shape rule: free when the screen follows it, the picture's shape otherwise.
    func applyWindowShapeRule() {
        if followsWindow {
            window.contentResizeIncrements = NSSize(width: 1, height: 1)   // (clears the aspect ratio)
        } else if let v = view, v.screenW > 0, v.screenH > 0 {
            window.contentAspectRatio = NSSize(width: v.screenW, height: v.screenH)
        }
    }

    /// The window changed size, shape or screen: ask for a matching screen once it settles.
    func screenSizeMayChange() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(sendScreenSize), object: nil)
        perform(#selector(sendScreenSize), with: nil, afterDelay: 0.6)
    }

    /// The size for the window as it is now, in 8-pixel steps (the screen server's too).
    func wantedScreenSize() -> (Int, Int) {
        let mode = screenSizeMode
        guard mode != .fixed, let v = view else { return (1920, 1080) }
        let b = v.bounds.size
        guard b.width >= 100, b.height >= 100 else { return (1920, 1080) }
        let scale = window.backingScaleFactor
        let aspect = b.width / b.height
        let area = min(mode.pixels, b.width * scale * b.height * scale)
        var h = (area / aspect).squareRoot(), w = h * aspect
        if w > 3840 { w = 3840; h = w / aspect }
        if h > 2400 { h = 2400; w = h * aspect }
        let wi = max(800, Int(w) / 8 * 8), hi = max(600, Int(h) / 8 * 8)
        return (wi, hi)
    }

    @objc func sendScreenSize() {
        guard conn.serverVersion >= 2 else { return }
        let (w, h) = wantedScreenSize()
        let games = gamesAt1080p || screenSizeMode == .fixed
        conn.requestSize(width: w, height: h, gameWidth: games ? 1920 : 0, gameHeight: games ? 1080 : 0)
    }

    @objc func chooseScreenSize(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = ScreenSizeMode(rawValue: raw) else { return }
        UserDefaults.standard.set(mode.rawValue, forKey: screenSizeKey)
        applyWindowShapeRule()
        if mode == .fixed { fitToPicture() }
        sendScreenSize()
    }

    @objc func toggleGamesAt1080p(_ sender: Any?) {
        UserDefaults.standard.set(!gamesAt1080p, forKey: gamesFixedKey)
        sendScreenSize()
    }

    /// View > Screen Size.
    func screenSizeMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Screen Size", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Screen Size")
        for mode in [ScreenSizeMode.window, .sharp, .fixed] {
            let m = NSMenuItem(title: mode.title, action: #selector(chooseScreenSize(_:)), keyEquivalent: "")
            m.representedObject = mode.rawValue
            m.target = self
            menu.addItem(m)
        }
        menu.addItem(.separator())
        let games = NSMenuItem(title: "Games at 1920 × 1080", action: #selector(toggleGamesAt1080p(_:)), keyEquivalent: "")
        games.target = self
        menu.addItem(games)
        item.submenu = menu
        return item
    }

    /// What the window's delegate hears.
    @objc func windowDidResize(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window, !window.inLiveResize else { return }
        noticeView?.place()
        if followsWindow { screenSizeMayChange() }
    }

    @objc func windowDidEndLiveResize(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        noticeView?.place()
        if followsWindow { screenSizeMayChange() }
    }

    @objc func windowDidChangeBackingProperties(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        if followsWindow { screenSizeMayChange() }
    }
}
