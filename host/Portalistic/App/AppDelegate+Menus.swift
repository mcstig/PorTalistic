// Portalistic — the menus: the Bottle menu's commands, the View menu, and which items
// are available when.

import AppKit

extension AppDelegate {
    @objc func restartSteam(_ sender: Any?) {
        guard confirm("Restart Steam?", "A game that's running closes. Steam is back in about half a minute.",
                      "Restart Steam") else { return }
        activity.run("Restarting Steam", ["steam"], log: "steam")
    }

    @objc func steamSettings(_ sender: Any?) {
        runQuietly(["settings"], log: "settings", failure: "Steam's settings didn't open.")
    }

    @objc func updateBottle(_ sender: Any?) {
        activity.run("Updating the bottle", ["update"], log: "update")
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
                      "Steam and any game that's running quit, then the VM stops. Start it again from the Bottle menu, or by opening Portalistic.",
                      "Shut Down") else { return }
        activity.run("Shutting down the VM", ["stop"], log: "stop")
    }

    @objc func releaseMouse(_ sender: Any?) { view.releaseMouse() }

    func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Portalistic", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        let update = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdatesNow(_:)), keyEquivalent: "")
        update.target = self
        appMenu.addItem(update)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Portalistic", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Portalistic", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let bottleItem = NSMenuItem()
        main.addItem(bottleItem)
        let bottleMenu = NSMenu(title: "Bottle")
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            bottleMenu.addItem(item)
        }
        add("Start the Bottle", #selector(startBottle(_:)))
        add("Restart Steam…", #selector(restartSteam(_:)))
        add("Open Steam Settings", #selector(steamSettings(_:)))
        bottleMenu.addItem(.separator())
        add("Add a Game Folder…", #selector(addGameFolder(_:)))
        add("Show Game Folders", #selector(showGameFolders(_:)))
        bottleMenu.addItem(.separator())
        add("Update the Bottle", #selector(updateBottle(_:)))
        add("Save Logs", #selector(saveLogs(_:)))
        add("Show Activity", #selector(showActivity(_:)))
        bottleMenu.addItem(.separator())
        add("Shut Down the VM…", #selector(shutDown(_:)))
        bottleItem.submenu = bottleMenu

        let viewItem = NSMenuItem()
        main.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        let full = NSMenuItem(title: "Toggle Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        full.keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(full)
        let release = NSMenuItem(title: "Release Mouse", action: #selector(releaseMouse(_:)), keyEquivalent: "\u{1b}")
        release.keyEquivalentModifierMask = [.command]
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
            || item.action == #selector(addGameFolder(_:)) || item.action == #selector(showGameFolders(_:)) {
            return !busy
        }
        if item.action == #selector(steamSettings(_:)) { return !busy && view.connected }
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
