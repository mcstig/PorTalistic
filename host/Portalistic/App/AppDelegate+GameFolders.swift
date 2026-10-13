// Portalistic — Bottle > Add a Game Folder… and Show Game Folders: places for games outside the
// VM's disk (a folder on this Mac, or a drive), through `bottle library`.

import AppKit

extension AppDelegate {
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

        let onDrive = url.path.hasPrefix("/Volumes/")
        let alert = NSAlert()
        alert.messageText = "Use “\(url.lastPathComponent)” for games?"
        alert.informativeText = (onDrive
            ? "Keep the drive connected while the bottle runs. "
            : "") + "The VM restarts to get the folder, which takes a minute or two. Quit any game that's running first."
        alert.addButton(withTitle: "Add and Make Default")
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        let answer = alert.runModal()
        guard answer != .alertThirdButtonReturn else { return }
        var args = ["library", "add", url.path]
        if answer == .alertFirstButtonReturn { args.append("--default") }
        activity.run("Adding a game folder", args, log: "library")
    }

    @objc func showGameFolders(_ sender: Any?) {
        activity.run("Game folders", ["library", "folders"], log: "library")
    }
}
