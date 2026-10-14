// Portalistic — the first launch on a Mac: no VM yet. The packaged app offers to set it up, and
// `bottle setup` downloads Portalistic's ready-made Linux system, makes the VM from it, starts
// it and installs Steam, with its progress on the starting screen.

import AppKit

extension AppDelegate {
    /// The VM isn't on this Mac yet (a packaged app: Lima keeps it in ~/.portalistic/lima, or in
    /// ~/.lima on a Mac that was set up with the kit).
    var needsSetup: Bool {
        guard BottleCommand.isPackaged else { return false }
        let env = ProcessInfo.processInfo.environment
        let name = env["VM_NAME"] ?? "steamos-bottle"
        let homes = env["LIMA_HOME"].map { [$0] }
            ?? [NSHomeDirectory() + "/.lima", NSHomeDirectory() + "/.portalistic/lima"]
        return !homes.contains { FileManager.default.fileExists(atPath: "\($0)/\(name)/lima.yaml") }
    }

    /// How big the download is (host/image.env in the app's kit), for the welcome screen.
    private var setupDownloadSize: String {
        guard let kit = BottleCommand.kitDir,
              let env = try? String(contentsOfFile: kit + "/host/image.env", encoding: .utf8),
              let line = env.split(separator: "\n").first(where: { $0.hasPrefix("PORTALISTIC_IMAGE_SIZE=") }),
              let bytes = Double(line.split(separator: "=").last ?? "") else { return "a few GB" }
        return String(format: "%.1f GB", bytes / 1e9)
    }

    func showSetup() {
        startView.show("Welcome to Portalistic",
                       detail: "Steam runs in a small Linux system on this Mac. Setting it up downloads \(setupDownloadSize), "
                           + "then Steam installs itself and asks you to sign in. Games go in the Games folder in your home folder; "
                           + "Game Folders > Add a Game Folder adds another folder or a drive.",
                       busy: false, button: "Set Up")
    }

    func runSetup() {
        let c = BottleCommand(["setup"], log: "setup")
        c.onLine = { [weak self] line in self?.startProgress(line) }
        c.onExit = { [weak self, unowned c] code in
            guard let self = self else { return }
            if code != 0 && !self.view.connected {
                self.starter = nil
                self.lastProblemLog = c.logPath
                self.startView.show("Portalistic isn't set up yet.", detail: c.problem, busy: false,
                                    button: "Try Again", log: true)
                return
            }
            self.startDone(code, c)
        }
        starter = c
        startView.show("Setting up Portalistic…", busy: true)
        if !c.start() {
            starter = nil
            startView.show("Couldn't run the bottle command.", detail: BottleCommand.script ?? "", busy: false,
                           button: "Try Again")
        }
    }
}
