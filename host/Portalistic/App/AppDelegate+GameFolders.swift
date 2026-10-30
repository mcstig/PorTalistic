// Portalistic — Game Folders > Add a Game Folder…, Remove a Game Folder… and Show Game Folders: places
// for games outside the VM's disk (a folder on this Mac, or a drive), through `bottle library`.
// Steam's own Add Drive can't see the Mac's drives (Steam runs in the VM, which sees only the
// folders shared with it). So when the app opens, and whenever a drive is connected, a drive that
// could hold games and isn't a game folder yet gets a notice (clicking it adds the drive), until
// "Don't offer this drive again"; and a game folder's drive that isn't connected gets a notice.

import AppKit

extension AppDelegate {
    struct GameFolder { let name, label, path: String }

    static let declinedDrivesKey = "DeclinedGameDrives"   // drives not to offer again (volume UUIDs)
    static var offeredThisRun: Set<String> = []           // (a drive's notice once per launch)

    @objc func addGameFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use for Games"
        panel.message = "Choose a folder on this Mac, or a drive: Portalistic makes a “Portalistic Library” folder on it. Games installed there are normal files on that drive."
        let games = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Games")
        if FileManager.default.fileExists(atPath: games.path) { panel.directoryURL = games }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        confirmGameFolder(url)
    }

    /// offered: from a drive's notice, which can be told not to come back for that drive.
    func confirmGameFolder(_ url: URL, offered: Bool = false) {
        let onDrive = url.path.hasPrefix("/Volumes/")
        let alert = NSAlert()
        alert.messageText = "Use “\(url.lastPathComponent)” for games?"
        alert.informativeText = (onDrive
            ? "Steam will list it in Settings > Storage. Keep the drive connected while you play. "
            : "") + "The VM restarts to get the folder, which takes a minute or two. Quit any game that's running first."
        alert.addButton(withTitle: "Add and Make Default")
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Not Now")
        if offered {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Don't offer this drive again"
        }
        let answer = alert.runModal()
        if offered, alert.suppressionButton?.state == .on {
            var declined = UserDefaults.standard.stringArray(forKey: AppDelegate.declinedDrivesKey) ?? []
            declined.append(driveID(url))
            UserDefaults.standard.set(declined, forKey: AppDelegate.declinedDrivesKey)
        }
        guard answer != .alertThirdButtonReturn else { return }
        var args = ["library", "add", url.path]
        if answer == .alertFirstButtonReturn { args.append("--default") }
        activity.run("Adding a game folder", args, log: "library")
    }

    @objc func removeGameFolder(_ sender: Any?) {
        let folders = gameFolders()
        guard !folders.isEmpty else {
            tell("There are no game folders to remove.", "Game Folders > Add a Game Folder… adds one.")
            return
        }
        let alert = NSAlert()
        alert.messageText = "Remove a game folder?"
        alert.informativeText = "Steam stops using it. Its games stay where they are, and adding the folder again "
            + "brings them back. The VM restarts, which takes a minute or two; quit any game that's running first."
        let pick = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 340, height: 26), pullsDown: false)
        for f in folders { pick.addItem(withTitle: "\(f.label) (\(f.path))") }
        alert.accessoryView = pick
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let f = folders[pick.indexOfSelectedItem]
        activity.run("Removing a game folder", ["library", "remove", f.name], log: "library")
    }

    @objc func showGameFolders(_ sender: Any?) {
        activity.run("Game folders", ["library", "folders"], log: "library")
    }

    /// The game folders (bottle library's list: NAME<TAB>LABEL<TAB>PATH lines).
    func gameFolders() -> [GameFolder] {
        let state = ProcessInfo.processInfo.environment["BOTTLE_STATE_DIR"] ?? NSHomeDirectory() + "/.config/steamos-bottle"
        let list = (try? String(contentsOfFile: state + "/libraries", encoding: .utf8)) ?? ""
        return list.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            return f.count >= 3 && !f[0].hasPrefix("#") ? GameFolder(name: f[0], label: f[1], path: f[2]) : nil
        }
    }

    /// When the app opens and whenever a drive is connected.
    func watchDrives() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didMountNotification, object: nil,
                                                          queue: .main) { [weak self] note in
            if let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL { self?.offerDrive(url) }
        }
        perform(#selector(checkDrivesAtLaunch), with: nil, afterDelay: 4)   // (the window laid out first)
    }

    /// A connected drive to offer, else a game folder's drive that isn't connected (one notice at a time).
    @objc func checkDrivesAtLaunch() {
        let drives = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil,
                                                           options: [.skipHiddenVolumes]) ?? []
        for url in drives where offerDrive(url) { return }
        let missing = gameFolders().filter { f in
            guard f.path.hasPrefix("/Volumes/") else { return false }
            let volume = "/Volumes/" + (f.path.dropFirst("/Volumes/".count).split(separator: "/").first.map(String.init) ?? "")
            return !FileManager.default.fileExists(atPath: volume)
        }
        guard let f = missing.first else { return }
        let others = missing.count > 1 ? " (and \(missing.count - 1) more)" : ""
        noticeView.show(problem: false, title: "“\(f.label)” isn't connected\(others)",
                        detail: "Its games show as unavailable in Steam until you connect it. "
                            + "Game Folders > Remove a Game Folder… takes it off the list.", seconds: 15)
    }

    /// A notice for a drive that suits games and isn't a game folder yet (unless declined).
    @discardableResult
    func offerDrive(_ url: URL) -> Bool {
        guard let name = driveForGames(url) else { return false }
        let id = driveID(url)
        let declined = UserDefaults.standard.stringArray(forKey: AppDelegate.declinedDrivesKey) ?? []
        guard !declined.contains(id), !AppDelegate.offeredThisRun.contains(id) else { return false }
        AppDelegate.offeredThisRun.insert(id)
        // (Oct 27) a drive that already has Portalistic games (from another Mac, say) says so
        let hasGames = FileManager.default.fileExists(atPath: url.appendingPathComponent("Portalistic Library/.portalistic-library").path)
        noticeView.show(problem: false,
                        title: hasGames ? "“\(name)” has Portalistic games on it: use them here?"
                                        : "“\(name)” is connected: use it for Steam games?",
                        detail: hasGames
                            ? "Click here to add the drive with its games (the VM restarts once to get it). "
                              + "Without a click, the next start of Portalistic adds it by itself."
                            : "Click here to add it. Steam's own Add Drive can't see your Mac's drives; "
                              + "Game Folders > Add a Game Folder… adds one any time.",
                        seconds: 20) { [weak self] in self?.confirmGameFolder(url, offered: true) }
        return true
    }

    func driveID(_ url: URL) -> String {
        (try? url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString) ?? url.path
    }

    /// The drive's name if it could hold games: an external drive in a Mac format (APFS or Mac OS
    /// Extended; the VM keeps Linux file details there), writable, 32 GB or more, not a Time
    /// Machine disk, and not already a game folder.
    func driveForGames(_ url: URL) -> String? {
        guard url.path.hasPrefix("/Volumes/") else { return nil }
        let keys: Set<URLResourceKey> = [.volumeIsLocalKey, .volumeIsInternalKey, .volumeIsReadOnlyKey,
                                         .volumeTypeNameKey, .volumeTotalCapacityKey, .volumeLocalizedNameKey]
        guard let v = try? url.resourceValues(forKeys: keys), v.volumeIsLocal == true,
              v.volumeIsInternal != true, v.volumeIsReadOnly != true,
              ["apfs", "hfs"].contains((v.volumeTypeName ?? "").lowercased()),
              (v.volumeTotalCapacity ?? 0) >= 32_000_000_000,
              !FileManager.default.fileExists(atPath: url.appendingPathComponent("Backups.backupdb").path)
        else { return nil }
        if gameFolders().contains(where: { $0.path == url.path || $0.path.hasPrefix(url.path + "/") }) { return nil }
        return v.volumeLocalizedName ?? url.lastPathComponent
    }
}
