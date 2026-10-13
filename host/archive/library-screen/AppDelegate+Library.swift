// Portalistic — showing the Library or Steam's window, reading the games, playing one; the
// toolbar switch and full screen.

import AppKit
import QuartzCore
import SwiftUI

extension NSToolbarItem.Identifier {
    static let showSwitch = NSToolbarItem.Identifier("LibraryOrSteam")
}

extension AppDelegate {
    /// Shows the Library or Steam's window (the VM's picture). Steam's window catches up on what
    /// changed behind the Library, and gets keyboard and mouse; the Library reads the games again
    /// when its list is more than 20 seconds old.
    func show(_ what: Showing, save: Bool = true) {
        showing = what
        if save { UserDefaults.standard.set(what == .library, forKey: libraryKey) }
        showSwitch?.selectedSegment = what == .library ? 0 : 1
        let lib = what == .library
        libraryView.isHidden = !lib
        view.isHidden = lib
        paintToolbar()
        view.covered = startVisible || lib
        if lib {
            view.focusLost()                      // keys held down in Steam's window: let go
            if !window.makeFirstResponder(libraryView) { window.makeFirstResponder(nil) }
            if Date().timeIntervalSince(libraryReadAt) > 20 { readLibrary() }
        } else {
            window.makeFirstResponder(view)
            view.redraw()
        }
        conn.setFrameRate(window.occlusionState.contains(.visible) ? frameRate() : 5)
    }

    /// Steam's window, to see a game start (or Steam's dialog for the game): the end of a
    /// double-click in the Library mustn't land on Steam.
    func showSteamForAction() {
        view.ignoreClicksUntil = CACurrentMediaTime() + 0.5
        show(.steam)
    }

    @objc func showLibrary(_ sender: Any?) { show(.library) }

    @objc func showSteam(_ sender: Any?) { show(.steam) }

    @objc func switchShowing(_ sender: NSSegmentedControl) {
        show(sender.selectedSegment == 0 ? .library : .steam)
    }

    /// Copies the list of games and their covers from the VM (bottle library --copy), then shows it.
    func readLibrary() {
        guard libraryReader == nil, view.connected, BottleCommand.available else { return }
        let c = BottleCommand(["library", "--copy"], log: "library")
        c.onExit = { [weak self, unowned c] code in self?.libraryRead(code, c) }
        libraryReader = c
        library.reading = true
        if !c.start() {
            libraryReader = nil
            library.reading = false
            library.message = "the bottle command didn't run."
            return
        }
        libraryTimer = Timer.scheduledTimer(timeInterval: 200, target: self, selector: #selector(libraryTimedOut),
                                            userInfo: nil, repeats: false)
    }

    /// The VM calls have time limits; this is in case the command itself hangs.
    @objc func libraryTimedOut() {
        libraryTimer = nil
        guard let c = libraryReader else { return }
        c.onExit = nil
        c.stop()
        libraryReader = nil
        library.reading = false
        library.message = "the bottle took too long to answer."
    }

    func libraryRead(_ code: Int32, _ c: BottleCommand) {
        libraryTimer?.invalidate()
        libraryTimer = nil
        libraryReader = nil
        libraryReadAt = Date()
        library.reading = false
        if code == 0 {
            library.needsUpdate = false
            library.message = library.load() ? nil : "the list from the bottle didn't read."
        } else {
            library.needsUpdate = c.lines.contains { $0.contains("library helper") }
            library.message = c.problem
        }
    }

    func play(_ g: Game) {
        if !library.isRunning(g) {
            runQuietly(["play", g.appid], log: "play", failure: "\(g.name) didn't start.")
        }
        showSteamForAction()
    }

    func openInSteam(_ url: String) {
        runQuietly(["steam-url", url], log: "steam-url", failure: "Steam didn't open that.")
        showSteamForAction()
    }

    /// Full screen: the toolbar and the menu bar slide in only when the pointer goes to the top.
    @objc func window(_ window: NSWindow, willUseFullScreenPresentationOptions proposed: NSApplication.PresentationOptions = [])
        -> NSApplication.PresentationOptions {
        [.fullScreen, .autoHideMenuBar, .autoHideToolbar]
    }
}

extension AppDelegate: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.showSwitch] }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.showSwitch] }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard id == .showSwitch else { return nil }
        let seg = NSSegmentedControl(labels: ["Library", "Steam"], trackingMode: .selectOne,
                                     target: self, action: #selector(switchShowing(_:)))
        seg.selectedSegment = showing == .library ? 0 : 1
        seg.setToolTip("Your games (⌘1)", forSegment: 0)
        seg.setToolTip("Steam's own window, and the game you're playing (⌘2)", forSegment: 1)
        showSwitch = seg
        let item = NSToolbarItem(itemIdentifier: id)
        item.view = seg
        item.label = "Show"
        return item
    }
}
