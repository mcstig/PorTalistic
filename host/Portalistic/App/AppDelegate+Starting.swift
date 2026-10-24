// Portalistic — starting the bottle (`bottle _up`), following the connection, and the
// app rebuilding itself when the kit has newer code.

import AppKit

extension AppDelegate {
    @objc func autoStart() {
        if needsSetup { setStartScreen(true); showSetup(); return }   // (first launch: asks first)
        if !view.connected { startBottle(nil) }
    }

    /// The starting screen over the VM's picture (no mouse capture while it's there).
    func setStartScreen(_ visible: Bool) {
        startView.isHidden = !visible
        view.covered = visible
    }

    func connectionChanged(_ up: Bool) {
        view.connected = up
        lostTimer?.invalidate()
        lostTimer = nil
        if up {
            screenTimer?.invalidate()
            screenTimer = nil
            padsBlocked = false
            pads.resendAll()
            applyWindowShapeRule()               // a screen server that follows the window frees its shape
            sendScreenSize()
            if conn.serverVersion >= 2 { hostStats.start() }
            if !rebuilding { setStartScreen(false) }
            window.makeFirstResponder(view)
            showFirstStartTipsIfNew()            // (once per Mac: what to expect from games)
            LocalNetworkAccess.shared.ask()      // (macOS's local-network permission, for the LAN's file servers)
        } else if !rebuilding {
            hostStats.stop()
            // A restart of the VM's screen server (an update) comes back within seconds.
            setStartScreen(true)
            startView.show("Reconnecting to the bottle…", busy: true)
            lostTimer = Timer.scheduledTimer(timeInterval: 10, target: self, selector: #selector(lostTimerFired),
                                             userInfo: nil, repeats: false)
        }
        updateSubtitle()
    }

    @objc func lostTimerFired() {
        lostTimer = nil
        guard !view.connected, starter == nil else { return }
        if activity.busy {
            startView.show("Portalistic is busy…", detail: "See Steam > Show Activity.", busy: true)
        } else {
            showStopped()
        }
    }

    /// A Steam menu job ended (an update, a shutdown...): if the screen is gone, say so.
    func activityEnded() {
        guard !view.connected, starter == nil, lostTimer == nil, !rebuilding else { return }
        showStopped()
    }

    func showStopped() {
        startView.show("The VM isn't running.",
                       detail: "Steam and its games run in a Linux VM on this Mac.", busy: false, button: "Start the VM")
    }

    @objc func startBottle(_ sender: Any?) {
        guard starter == nil, !view.connected else { return }
        guard !activity.busy else {
            startView.show("Portalistic is busy…", detail: "See Steam > Show Activity.", busy: true)
            return
        }
        screenTimer?.invalidate()
        screenTimer = nil
        if needsSetup { runSetup(); return }
        guard BottleCommand.available else {
            startView.show("The VM isn't running.",
                           detail: "This copy of the app doesn't know where the kit is. In Terminal: bottle window",
                           busy: false)
            return
        }
        let c = BottleCommand(["_up"], log: "start")
        c.onLine = { [weak self] line in self?.startProgress(line) }
        c.onExit = { [weak self, unowned c] code in self?.startDone(code, c) }
        starter = c
        startView.show("Starting the bottle…", busy: true)
        if !c.start() {
            starter = nil
            startView.show("Couldn't run the bottle command.", detail: BottleCommand.script ?? "", busy: false,
                           button: "Try Again")
        }
    }

    func startProgress(_ line: String) {
        guard !view.connected, !line.isEmpty else { return }
        if line.hasPrefix("==> ") {
            // "Starting the VM with KosmicKrisp (settings: ...)…": the step, without the settings
            let step = readableLine(line).replacingOccurrences(of: " \\(settings:[^)]*\\)", with: "",
                                                              options: .regularExpression)
            startView.show(step, detail: step.hasPrefix("Starting the VM") ? "This takes about half a minute." : "",
                           busy: true)
        } else if !line.hasPrefix("warn:") {
            startView.setDetail(readableLine(line))   // Lima's progress while the VM boots
        }
    }

    func startDone(_ code: Int32, _ c: BottleCommand) {
        starter = nil
        if view.connected {
            // The screen is there, but something after it didn't start (Steam, say).
            if code != 0 {
                let alert = NSAlert()
                alert.messageText = "Part of the bottle didn't start"
                alert.informativeText = c.problem + "\n\nSteam > Restart Steam tries again; Steam > Save Logs saves what helps find out why."
                alert.beginSheetModal(for: window, completionHandler: nil)
            }
            return
        }
        if code == 0 {
            startView.show("Waiting for the bottle's screen…", busy: true)
            startedCommand = c
            screenTimer = Timer.scheduledTimer(timeInterval: 20, target: self, selector: #selector(screenTimerFired),
                                               userInfo: nil, repeats: false)
        } else {
            lastProblemLog = c.logPath
            startView.show("The bottle didn't start.", detail: c.problem, busy: false, button: "Try Again", log: true)
        }
    }

    @objc func screenTimerFired() {
        screenTimer = nil
        guard !view.connected, starter == nil, let c = startedCommand else { return }
        lastProblemLog = c.logPath
        startView.show("The bottle started, but its screen didn't appear.",
                       detail: "Steam > Update the VM can fix a VM that's missing pieces.",
                       busy: false, button: "Try Again", log: true)
    }

    @objc func showProblemLog(_ sender: Any?) {
        guard let path = lastProblemLog else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    /// The kit has newer app code than this build (an update arrived, or an edit in Xcode): a
    /// file in host/Portalistic changed after this executable was built.
    func appIsOutdated() -> Bool {
        guard !BottleCommand.isPackaged else { return false }   // (a packaged app updates as a whole)
        guard let kit = BottleCommand.kitDir, let exe = Bundle.main.executablePath else { return false }
        let fm = FileManager.default
        guard let built = (try? fm.attributesOfItem(atPath: exe))?[.modificationDate] as? Date,
              let files = fm.enumerator(atPath: kit + "/host/Portalistic") else { return false }
        for case let f as String in files where f.hasSuffix(".swift") {
            let path = kit + "/host/Portalistic/" + f
            if let t = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date, t > built { return true }
        }
        return false
    }

    /// Builds the new version; the build quits this copy and opens the new one. If this copy is
    /// still here when the build ends, the build failed and this version carries on.
    func rebuildApp() {
        let c = BottleCommand(["_rebuild"], log: "rebuild")
        c.onExit = { [weak self, unowned c] code in
            // Still here: the build failed (or there was nothing to build), so this copy carries on.
            guard let self = self else { return }
            self.starter = nil
            self.rebuilding = false
            if code != 0 || c.lines.contains(where: { $0.contains("failed") }) {
                self.tell("Portalistic couldn't build its new version",
                          "This version carries on. Why the build failed: logs/app-build.log in the kit folder.")
            }
            if self.view.connected { self.setStartScreen(false); self.window.makeFirstResponder(self.view) } else { self.startBottle(nil) }
        }
        starter = c
        rebuilding = true
        startView.show("Updating Portalistic…",
                       detail: "A new version of the app arrived; building it takes a minute or so.", busy: true)
        if !c.start() {
            starter = nil
            rebuilding = false
            startBottle(nil)
        }
    }
}
