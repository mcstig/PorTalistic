// Portalistic — the menus: the Steam menu's commands, the View menu, and which items
// are available when.

import AppKit

extension AppDelegate {
    @objc func restartSteam(_ sender: Any?) {
        guard confirm("Restart Steam?", "A game that's running closes. Steam is back in about half a minute.",
                      "Restart Steam") else { return }
        activity.run("Restarting Steam", ["steam"], log: "steam")
    }

    /// The watcher found the VM's disk almost full (a kind-3 notice): the user chooses between a bigger
    /// disk (5 GB more, the VM restarts) and moving games out of it in Steam's storage settings.
    func askAboutVMDisk(title: String, detail: String) {
        guard !askingAboutDisk else { return }
        askingAboutDisk = true
        defer { askingAboutDisk = false }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail + "\n\nMake the disk 5 GB bigger (it takes Mac space only as it fills; Steam restarts, about a minute), "
            + "or move the games that are on it to a game folder in Steam's storage settings (games only: Proton, the Steam Linux Runtimes and Steamworks belong on this disk)."
        alert.addButton(withTitle: "Make the Disk Bigger")
        alert.addButton(withTitle: "Move Games Out of It…")
        alert.addButton(withTitle: "Not Now")
        if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            activity.run("Making the VM's disk bigger", ["disk", "grow"], log: "disk-grow") { [weak self] code, _ in
                if code == 0 { self?.activity.window?.orderOut(nil) }
            }
        case .alertSecondButtonReturn:
            runQuietly(["steam-url", "steam://settings/storage"], log: "settings", failure: "Steam's storage settings didn't open.")
        default:
            break
        }
    }

    @objc func steamSettings(_ sender: Any?) {
        runQuietly(["settings"], log: "settings", failure: "Steam's settings didn't open.")
    }

    /// Desktop Mode: KDE Plasma takes the screen (Steam stays running, in a window). The first time
    /// it downloads and installs it, which the Activity window shows; it closes itself when the switch worked.
    @objc func switchToDesktopMode(_ sender: Any?) {
        guard confirm("Switch to Desktop Mode?",
                      "Steam's Big Picture closes and a Linux desktop (KDE Plasma, like the Steam Deck's) opens in this window. "
                      + "It installs itself in the background after Portalistic starts (about 550 MB, then the emulators it comes with: Ryujinx, RPCS3, Play!, RetroArch, about 4.5 GB); if that isn't done yet, the switch waits for it. “Return to Game Mode” on the desktop, or this menu, switches back.",
                      "Switch to Desktop Mode") else { return }
        activity.run("Switching to Desktop Mode", ["mode", "desktop"], log: "mode") { [weak self] code, _ in
            if code == 0 { self?.vmMode = "desktop"; self?.activity.window?.orderOut(nil) } else { self?.refreshMode() }
        }
    }

    /// Game Mode from the menu asks first (Nov 3), as Desktop Mode does: leaving the desktop logs out of
    /// it, and what's open there closes (what doesn't close by itself after about 12 s is ended).
    @objc func switchToGameMode(_ sender: Any?) {
        guard confirm("Switch to Game Mode?",
                      "The Linux desktop closes, with the apps open on it (save your work in them first; any that are still open after about 12 seconds are ended), "
                      + "and Steam's Big Picture comes back in this window. “Switch to Desktop Mode” in this menu opens the desktop again.",
                      "Switch to Game Mode") else { return }
        let c = BottleCommand(["mode", "game"], log: "mode")
        c.onExit = { [weak self, unowned c] code in
            if code == 0 { self?.vmMode = "game" } else { self?.tell("Game Mode didn't start.", c.problem); self?.refreshMode() }
        }
        if !c.start() { tell("Couldn't run Portalistic's helper script.", BottleCommand.script ?? ""); return }
        quietCommands.removeAll { !$0.running }
        quietCommands.append(c)
    }

    /// Which mode the VM's screen is in, for the Steam menu (it shows only the switch to the other one):
    /// asked when the screen connects; the VM tells the app of a switch made on the desktop (a notice).
    func refreshMode() {
        let c = BottleCommand(["mode", "status"], log: "mode-status")
        c.onExit = { [weak self, unowned c] code in
            guard code == 0, let line = c.lines.last(where: { $0.hasPrefix("mode: ") }) else { return }
            let m = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            if m == "desktop" || m == "game" { self?.vmMode = m }
        }
        guard c.start() else { return }
        quietCommands.removeAll { !$0.running }
        quietCommands.append(c)
    }

    @objc func updateBottle(_ sender: Any?) {
        activity.run("Updating the VM", ["update"], log: "update")
    }

    @objc func saveLogs(_ sender: Any?) {
        activity.run("Saving logs", ["log", "export"], log: "logs") { code, c in
            // "==> Saved 312K of logs to /path/vm-logs-....tgz (and mac-logs-....txt)": show it in Finder
            guard code == 0, let line = c.lines.last(where: { $0.contains(" of logs to ") }),
                  let r = line.range(of: " of logs to ") else { return }
            var path = String(line[r.upperBound...])
            if let p = path.range(of: " (and ") { path = String(path[..<p.lowerBound]) }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
    }

    @objc func showActivity(_ sender: Any?) { activity.showWindow(nil) }

    @objc func shutDown(_ sender: Any?) {
        guard confirm("Shut down the VM?",
                      "Steam and any game that's running quit, then the VM stops. Start it again from the Steam menu, or by opening Portalistic.",
                      "Shut Down") else { return }
        activity.run("Shutting down the VM", ["stop"], log: "stop")
    }

    @objc func releaseMouse(_ sender: Any?) { view.releaseMouse() }

    static let patreonURL = URL(string: "https://www.patreon.com/PorTalistic")!

    @objc func openPatreon(_ sender: Any?) { NSWorkspace.shared.open(AppDelegate.patreonURL) }

    func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Portalistic", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        let update = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdatesNow(_:)), keyEquivalent: "")
        update.target = self
        appMenu.addItem(update)
        let move = NSMenuItem(title: "Move to Applications…", action: #selector(moveToApplicationsMenu(_:)), keyEquivalent: "")
        move.target = self
        move.isHidden = !Installation.canOfferMove          // (only a copy outside Applications offers it)
        appMenu.addItem(move)
        let tips = NSMenuItem(title: "Good to Know…", action: #selector(showTipsMenu(_:)), keyEquivalent: "")
        tips.target = self
        appMenu.addItem(tips)
        let patreon = NSMenuItem(title: "Support Portalistic on Patreon", action: #selector(openPatreon(_:)), keyEquivalent: "")
        patreon.target = self
        appMenu.addItem(patreon)
        appMenu.addItem(.separator())
        let uninstall = NSMenuItem(title: "Uninstall Portalistic…", action: #selector(uninstallPortalistic(_:)), keyEquivalent: "")
        uninstall.target = self
        appMenu.addItem(uninstall)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Portalistic", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Portalistic", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        /// A menu of plain items in the menu bar, after the Steam menu.
        func makeMenu(_ title: String, _ entries: [(String, Selector)]) {
            let item = NSMenuItem()
            let menu = NSMenu(title: title)
            for (name, action) in entries {
                let entry = NSMenuItem(title: name, action: action, keyEquivalent: "")
                entry.target = self
                menu.addItem(entry)
            }
            item.submenu = menu
            main.addItem(item)
        }

        let bottleItem = NSMenuItem()
        main.addItem(bottleItem)
        let bottleMenu = NSMenu(title: "Steam")
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            bottleMenu.addItem(item)
        }
        add("Start the VM", #selector(startBottle(_:)))
        add("Restart Steam…", #selector(restartSteam(_:)))
        add("Open Steam Settings", #selector(steamSettings(_:)))
        add("Switch to Desktop Mode…", #selector(switchToDesktopMode(_:)))
        add("Switch to Game Mode…", #selector(switchToGameMode(_:)))
        bottleMenu.addItem(.separator())
        add("Update the VM", #selector(updateBottle(_:)))
        add("Save Logs", #selector(saveLogs(_:)))
        add("Show Activity", #selector(showActivity(_:)))
        bottleMenu.addItem(.separator())
        add("Shut Down the VM…", #selector(shutDown(_:)))
        bottleItem.submenu = bottleMenu

        // The stores whose games Steam in the bottle shows, and the places games are kept.
        makeMenu("Stores", [("GOG Games…", #selector(showGOGGames(_:))),
                            ("Epic Games…", #selector(showEpicGames(_:)))])
        makeMenu("Game Folders", [("Add a Game Folder…", #selector(addGameFolder(_:))),
                                  ("Remove a Game Folder…", #selector(removeGameFolder(_:))),
                                  ("Show Game Folders", #selector(showGameFolders(_:)))])

        let viewItem = NSMenuItem()
        main.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        let full = NSMenuItem(title: "Toggle Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        full.keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(full)
        // (Oct 28: ⌘Esc opens macOS 26's game overlay, which then kept the mouse; the release is
        // Control and Option pressed together now, as in Parallels and VMware: BottleView)
        let release = NSMenuItem(title: "Release Mouse (⌃⌥)", action: #selector(releaseMouse(_:)), keyEquivalent: "")
        release.target = self
        viewMenu.addItem(release)
        viewMenu.addItem(.separator())
        let sharp = NSMenuItem(title: "Sharp Scaling (MetalFX)", action: #selector(toggleSharp(_:)), keyEquivalent: "")
        sharp.target = self
        viewMenu.addItem(sharp)
        let smooth = NSMenuItem(title: "Smooth Motion (up to 120 fps)", action: #selector(toggleSmooth(_:)), keyEquivalent: "")
        smooth.target = self
        viewMenu.addItem(smooth)
        viewMenu.addItem(.separator())
        viewMenu.addItem(screenSizeMenu())
        viewMenu.addItem(.separator())
        let info = NSMenuItem(title: "Show Stream Info", action: #selector(toggleInfo(_:)), keyEquivalent: "i")
        info.keyEquivalentModifierMask = [.command, .option]
        info.target = self
        viewMenu.addItem(info)
        viewItem.submenu = viewMenu

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = main
    }
}

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let busy = starter != nil || activity.busy
        if item.action == #selector(startBottle(_:)) { return !busy && !view.connected }
        if item.action == #selector(restartSteam(_:)) || item.action == #selector(updateBottle(_:))
            || item.action == #selector(saveLogs(_:)) || item.action == #selector(shutDown(_:))
            || item.action == #selector(addGameFolder(_:)) || item.action == #selector(showGameFolders(_:))
            || item.action == #selector(removeGameFolder(_:)) {
            return !busy
        }
        if item.action == #selector(uninstallPortalistic(_:)) || item.action == #selector(moveToApplicationsMenu(_:)) { return !busy }
        if item.action == #selector(steamSettings(_:)) { return !busy && view.connected }
        if item.action == #selector(switchToDesktopMode(_:)) || item.action == #selector(switchToGameMode(_:)) {
            // only the switch to the other mode (both while the mode isn't known yet)
            item.isHidden = vmMode == (item.action == #selector(switchToDesktopMode(_:)) ? "desktop" : "game")
            return !busy && view.connected
        }
        if item.action == #selector(checkForUpdatesNow(_:)) {
            item.title = AppDelegate.availableUpdate.map { "Update to \($0)…" } ?? "Check for Updates…"
            return !activity.busy
        }
        if item.action == #selector(toggleSharp(_:)) {
            item.state = (UserDefaults.standard.object(forKey: sharpKey) as? Bool ?? true) ? .on : .off
            return view.renderer != nil
        }
        if item.action == #selector(toggleSmooth(_:)) {
            item.state = (UserDefaults.standard.object(forKey: smoothKey) as? Bool ?? true) ? .on : .off
            return fixedFPS == nil
        }
        if item.action == #selector(toggleInfo(_:)) { item.state = infoTimer != nil ? .on : .off }
        if item.action == #selector(chooseScreenSize(_:)) {
            item.state = (item.representedObject as? String) == screenSizeMode.rawValue ? .on : .off
        }
        if item.action == #selector(toggleGamesAt1080p(_:)) {
            item.state = gamesAt1080p ? .on : .off
            return screenSizeMode != .fixed
        }
        return true
    }
}
