// Portalistic — the app: its window (the VM's picture, which is Steam in Big Picture, and the
// starting screen), the connection's callbacks, and what happens as the window and the app gain
// or lose focus. The rest of AppDelegate is in its extensions: +Starting, +Menus, +Picture,
// +Quitting.

import AppKit
import CoreGraphics
import QuartzCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var view: BottleView!
    var startView: StartView!
    let conn = Connection()
    var pads: Pads!
    var padsBlocked = false                       // the VM said it can't create controllers
    var noticeView: NoticeView!                   // a notice from the VM over the picture
    var progressCard: ProgressCard!               // "please wait" while the VM gets Steam ready
    var hostStats: HostStats!                     // the Mac's GPU numbers, for Steam's performance monitor

    lazy var activity: ActivityWindow = {
        let a = ActivityWindow()
        a.onFinish = { [weak self] in self?.activityEnded() }
        return a
    }()

    var starter: BottleCommand?                   // bringing the bottle up (or the app's rebuild)
    var rebuilding = false
    // Timers call @objc methods (target/selector): no closures crossing into the main actor.
    var lostTimer: Timer?                         // the screen went away: stopped, or just a restart?
    var screenTimer: Timer?                       // the bottle started: waiting for its screen
    var startedCommand: BottleCommand?            // ...the start that screenTimer waits on
    var lastProblemLog: String?                   // what Show Log opens

    /// The app's bundle identifier until Oct 13, 2026 (it's io.github.mcstig.portalistic now).
    static let legacyBundleID = "local.steamos-bottle.window"

    /// Settings saved under the old identifier (window size, screen size, scaling...): copied
    /// over once, without replacing any set since.
    static func adoptLegacySettings() {
        let d = UserDefaults.standard
        guard Bundle.main.bundleIdentifier != legacyBundleID, !d.bool(forKey: "AdoptedLegacySettings") else { return }
        for (key, value) in d.persistentDomain(forName: legacyBundleID) ?? [:] where d.object(forKey: key) == nil {
            d.set(value, forKey: key)
        }
        d.set(true, forKey: "AdoptedLegacySettings")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.adoptLegacySettings()
        if let test = Installation.env["PORTALISTIC_SELFTEST"] { runSelfTest(test); return }   // (host/tests: AppDelegate+Install.swift)
        if offerInstall() { return }            // opened from outside Applications: the copy there takes over
        finishMove()                            // (this is that copy: the one it came from goes to the Trash)
        // One copy at a time: two would keep taking the VM's screen from each other (it serves
        // one window). A copy opened from elsewhere (Xcode's debug build, say) replaces the one
        // already open, as does a copy from before the identifier changed; the VM and the game
        // carry on.
        let me = ProcessInfo.processInfo.processIdentifier
        for id in Set([Bundle.main.bundleIdentifier ?? "", AppDelegate.legacyBundleID]) {
            for other in NSRunningApplication.runningApplications(withBundleIdentifier: id) where other.processIdentifier != me {
                other.forceTerminate()
            }
        }
        buildMenu()
        let size = largestContentSize(for: CGSize(width: 1920, height: 1080))
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        view = BottleView(conn: conn)
        view.frame = content.bounds
        view.autoresizingMask = [.width, .height]
        content.addSubview(view)
        startView = StartView(frame: content.bounds)
        startView.autoresizingMask = [.width, .height]
        startView.button.target = self
        startView.button.action = #selector(startBottle(_:))
        startView.logButton.target = self
        startView.logButton.action = #selector(showProblemLog(_:))
        content.addSubview(startView)
        progressCard = ProgressCard(frame: NSRect(x: 0, y: 0, width: 420, height: 90))
        content.addSubview(progressCard)          // what the VM is doing while Steam isn't there (bottle-splash)
        noticeView = NoticeView(frame: NSRect(x: 0, y: 0, width: 400, height: 60))
        content.addSubview(noticeView)            // above the picture and the starting screen
        hostStats = HostStats(conn: conn)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Portalistic"
        window.isReleasedWhenClosed = false       // the app may stay open with the Activity window
        window.appearance = NSAppearance(named: .darkAqua)
        window.titlebarAppearsTransparent = true  // a black title bar over the black picture
        window.titlebarSeparatorStyle = .none
        window.contentView = content
        window.contentMinSize = NSSize(width: 800, height: 450)
        window.collectionBehavior = [.fullScreenPrimary]
        window.backgroundColor = .black
        window.contentAspectRatio = NSSize(width: 1920, height: 1080)   // no black bars when resizing
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("SteamOSBottleMain")   // first open: as big as the screen allows
        fitToPicture()                            // a frame saved by a version with a toolbar
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)

        view.onCaptureChange = { [weak self] on in
            self?.window.title = on ? "Portalistic — mouse captured (⌘⎋ releases it)" : "Portalistic"
        }
        pads = Pads(conn: conn)
        pads.onChange = { [weak self] in self?.updateSubtitle() }
        updateSubtitle()                         // controllers already connected at launch
        conn.onConnected = { [weak self] up in self?.connectionChanged(up) }
        conn.onRumble = { [weak self] pad, strong, weak, seconds in
            self?.pads.rumble(pad, strong: strong, weak: weak, seconds: seconds)
        }
        conn.onPadStatus = { [weak self] ok in
            self?.padsBlocked = !ok
            self?.updateSubtitle()
        }
        conn.onSize = { [weak self] w, h in
            guard let self = self, let v = self.view, v.screenW != w || v.screenH != h, w > 0, h > 0 else { return }
            v.screenW = w; v.screenH = h
            // the window keeps the picture's shape, unless the screen follows the window
            if !self.followsWindow { self.window.contentAspectRatio = NSSize(width: w, height: h) }
            v.redraw()
        }
        conn.onNotice = { [weak self] kind, title, details, seconds in
            guard let self = self else { return }
            if kind == 2 {   // progress: a card in the middle that stays until the next one (an empty one, or "-", takes it down)
                let text = title == "-" ? "" : title
                self.progressCard.show(text: text, detail: details)
                return
            }
            self.noticeView.show(problem: kind == 1, title: title, detail: details, seconds: seconds)
            if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        }
        conn.onFrame = { [weak self] fb in self?.view.show(fb) }
        view.renderer?.sharpScaling = UserDefaults.standard.object(forKey: sharpKey) as? Bool ?? true
        conn.setFrameRate(frameRate())
        conn.onCursor = { [weak self] visible in
            guard let v = self?.view else { return }
            v.remoteCursorVisible = visible
            v.refreshCapture()
        }

        if appIsOutdated() {
            rebuildApp()
        } else {
            startView.show("Connecting to the bottle…", busy: true)
            // Already running (opened by `bottle window`, or reopened): the screen answers within
            // a second. Otherwise start what's missing.
            perform(#selector(autoStart), with: nil, afterDelay: 2)
        }
        setStartScreen(true)
        conn.start()
        scheduleUpdateChecks()
        watchDrives()

        if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
    }

    /// A bottle command without the Activity window; only a failure says something.
    func runQuietly(_ args: [String], log: String, failure: String) {
        let c = BottleCommand(args, log: log)
        c.onExit = { [weak self, unowned c] code in
            guard code != 0 else { return }
            self?.tell(failure, c.problem)
        }
        if !c.start() { tell("Couldn't run the bottle command.", BottleCommand.script ?? ""); return }
        quietCommands.removeAll { !$0.running }
        quietCommands.append(c)
    }

    /// A window frame saved with a different title bar (an earlier version had a toolbar) leaves
    /// a picture with bars at the sides: the content gets the picture's shape again, as big as fits.
    func fitToPicture() {
        let shape = window.contentAspectRatio
        guard shape.width > 0, shape.height > 0, let screen = window.screen ?? NSScreen.main else { return }
        let content = window.contentRect(forFrameRect: window.frame).size
        let chrome = window.frame.height - content.height
        var w = content.width, h = (w * shape.height / shape.width).rounded()
        let maxH = screen.visibleFrame.height - chrome
        if h > maxH { h = maxH.rounded(.down); w = (h * shape.width / shape.height).rounded(.down) }
        guard abs(h - content.height) > 1 || abs(w - content.width) > 1 else { return }
        var f = window.frameRect(forContentRect: NSRect(origin: .zero, size: NSSize(width: w, height: h)))
        f.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - f.height)   // the top stays put
        window.setFrame(window.constrainFrameRect(f, to: screen), display: false)
    }

    func confirm(_ message: String, _ info: String, _ action: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    var quietCommands: [BottleCommand] = []           // kept until they finish

    func tell(_ message: String, _ info: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.runModal()
    }

    /// The biggest window content of the screen's shape that fits on the Mac's screen.
    func largestContentSize(for screen: CGSize) -> CGSize {
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.size ?? CGSize(width: 1280, height: 800)
        let titleBar: CGFloat = 32
        let s = min(visible.width / screen.width, (visible.height - titleBar) / screen.height)
        return CGSize(width: (screen.width * s).rounded(.down), height: (screen.height * s).rounded(.down))
    }

    /// Under the title: the controllers in use, or why they can't be.
    func updateSubtitle() {
        let names = pads?.names ?? []
        if names.isEmpty {
            window.subtitle = ""
        } else if padsBlocked {
            window.subtitle = "Controllers can't reach the VM yet: choose Steam > Update the VM"
        } else {
            // Several: in player order, since games listen to player 1 (the one in use, see Pads)
            window.subtitle = names.count == 1 ? "Controller: " + names[0]
                : names.enumerated().map { "Player \($0.offset + 1): \($0.element)" }.joined(separator: " · ")
        }
    }

    var leaving = false
    var installing = false                 // moving to Applications: no quitting when the alert closes (AppDelegate+Quitting)
    let dontAskKey = "QuitWithoutAsking"

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        // Hidden (minimized, covered, another Space): a few frames a second are plenty.
        if window.occlusionState.contains(.visible) {
            conn.setFrameRate(frameRate())
            view?.redraw()                   // catches up on what changed while it was hidden
        } else {
            conn.setFrameRate(5)
        }
    }

    func windowDidChangeScreen(_ notification: Notification) {
        conn.setFrameRate(frameRate())       // a different display, maybe a different refresh rate
        if followsWindow { screenSizeMayChange() }   // ...and maybe another pixel density
    }

    let sharpKey = "SharpScaling", smoothKey = "SmoothMotion"
    var infoTimer: Timer?
    var infoAt = CACurrentMediaTime()
    var shownAt = 0

    func applicationDidBecomeActive(_ notification: Notification) { view?.refreshCapture(); pads?.resendAll() }

    func applicationDidResignActive(_ notification: Notification) { view?.focusLost(); pads?.forget() }

    func windowDidBecomeKey(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        view?.refreshCapture(); pads?.resendAll()
    }

    func windowDidResignKey(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        view?.focusLost(); pads?.forget()
    }

    func applicationWillTerminate(_ notification: Notification) { view?.focusLost() }

    /// Clicking the Dock icon brings the window back (minimized, or behind the Activity window).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !window.isVisible || window.isMiniaturized { window.makeKeyAndOrderFront(nil) }
        return true
    }
}
