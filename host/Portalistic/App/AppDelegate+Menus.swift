// Portalistic — the menus: the Steam menu's commands, the View menu, and which items
// are available when.

import AppKit

extension AppDelegate {
    @objc func restartSteam(_ sender: Any?) {
        guard confirm("Restart Steam?", "A game that's running closes. Steam is back in about half a minute.",
                      "Restart Steam") else { return }
        activity.run("Restarting Steam", ["steam"], log: "steam")
    }

    /// Steam's own interface (Big Picture) is drawn either on the Mac's GPU or on the Linux system's
    /// processor. Portalistic tries the GPU by itself and goes back if it can't; this lets people pick
    /// by hand, or try again after it went back.
    /// Asks where Steam's interface should draw; the choice in use is shown greyed out (Oct 23:
    /// choosing it again used to restart Steam for nothing). `bottle steam-gpu status` says which.
    @objc func chooseSteamInterface(_ sender: Any?) {
        guard starter == nil, !activity.busy else { showActivity(nil); return }
        let status = BottleCommand(["steam-gpu", "status"], log: "steam-gpu-status")
        status.onExit = { [weak self] _ in
            let now = status.lines.last(where: { $0 == "gpu" || $0 == "cpu" }) ?? ""
            self?.askSteamInterface(current: now)
        }
        if !status.start() { askSteamInterface(current: "") }
    }

    private func askSteamInterface(current: String) {
        let alert = NSAlert()
        alert.messageText = "Where should Steam's interface be drawn?"
        var text = "On the Mac's GPU it is smoother and leaves the processor free. Portalistic tries that by itself "
            + "and goes back to the processor if it doesn't work. Either way Steam restarts (about a minute, up to five "
            + "when it tries the GPU); a game that's running closes."
        switch current {
        case "gpu": text += "\n\nRight now it draws on the Mac's GPU."
        case "cpu": text += "\n\nRight now it draws on the processor."
        default: break
        }
        alert.informativeText = text
        let gpu = alert.addButton(withTitle: current == "gpu" ? "Using the Mac's GPU" : "Use the Mac's GPU")
        let cpu = alert.addButton(withTitle: current == "cpu" ? "Using the Processor" : "Use the Processor")
        alert.addButton(withTitle: "Cancel")
        gpu.isEnabled = current != "gpu"
        cpu.isEnabled = current != "cpu"
        if current == "gpu" { cpu.keyEquivalent = "\r"; gpu.keyEquivalent = "" }
        switch alert.runModal() {
        case .alertFirstButtonReturn where current != "gpu":
            activity.run("Steam's interface on the Mac's GPU", ["steam-gpu", "on"], log: "steam-gpu")
        case .alertSecondButtonReturn where current != "cpu":
            activity.run("Steam's interface on the processor", ["steam-gpu", "off"], log: "steam-gpu")
        default:
            break
        }
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
                      + "The first time it downloads about 550 MB. “Return to Game Mode” on the desktop, or this menu, switches back.",
                      "Switch to Desktop Mode") else { return }
        activity.run("Switching to Desktop Mode", ["mode", "desktop"], log: "mode") { [weak self] code, _ in
            if code == 0 { self?.activity.window?.orderOut(nil) }
        }
    }

    @objc func switchToGameMode(_ sender: Any?) {
        runQuietly(["mode", "game"], log: "mode", failure: "Game Mode didn't start.")
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
        add("Steam's Interface: GPU or Processor…", #selector(chooseSteamInterface(_:)))
        add("Switch to Desktop Mode…", #selector(switchToDesktopMode(_:)))
        add("Switch to Game Mode", #selector(switchToGameMode(_:)))
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
            || item.action == #selector(removeGameFolder(_:)) || item.action == #selector(chooseSteamInterface(_:)) {
            return !busy
        }
        if item.action == #selector(uninstallPortalistic(_:)) || item.action == #selector(moveToApplicationsMenu(_:)) { return !busy }
        if item.action == #selector(steamSettings(_:)) { return !busy && view.connected }
        if item.action == #selector(switchToDesktopMode(_:)) || item.action == #selector(switchToGameMode(_:)) {
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
