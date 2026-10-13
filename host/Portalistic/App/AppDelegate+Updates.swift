// Portalistic — updating the app from its GitHub releases (`bottle app-update`, in host/bottle).
//
// The packaged app looks as soon as it opens: a newer version is offered right away, on the
// window (Update / Later / What's New). While the app stays open it looks again once a day; a
// version found then shows as a notice over the picture (nothing pops up over a game) and in the
// app menu, where Update to… offers it. Installing it downloads the new copy, checks its
// signature, swaps it in and opens it; the VM, Steam and a game keep running meanwhile.

import AppKit

extension AppDelegate {
    enum UpdateCheck { case atLaunch, daily, asked }

    static var availableUpdate: String?          // a newer version GitHub has, once a check found it
    static var offeringUpdate = false            // the update question is on screen
    static let skippedUpdateKey = "SkippedUpdateVersion"

    func scheduleUpdateChecks() {
        guard BottleCommand.isPackaged else { return }
        perform(#selector(checkForUpdatesAtLaunch), with: nil, afterDelay: 1)
        let t = Timer(timeInterval: 24 * 3600, target: self, selector: #selector(checkForUpdatesDaily),
                      userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
    }

    @objc func checkForUpdatesAtLaunch() { checkForUpdates(.atLaunch) }

    @objc func checkForUpdatesDaily() { checkForUpdates(.daily) }

    @objc func checkForUpdatesNow(_ sender: Any?) { checkForUpdates(.asked) }

    func checkForUpdates(_ when: UpdateCheck) {
        guard BottleCommand.isPackaged else {
            if when == .asked {
                tell("This copy of Portalistic doesn't update itself.",
                     "It was built from the kit: updating the kit rebuilds it.")
            }
            return
        }
        let c = BottleCommand(["app-update", "check"], log: "app-update-check")
        c.onExit = { [weak self, unowned c] code in
            guard let self = self else { return }
            let answer = c.lines.last(where: { line in
                ["update ", "replace ", "current "].contains { line.hasPrefix($0) } }) ?? ""
            let words = answer.split(separator: " ").map(String.init)
            guard code == 0, let kind = words.first else {
                if when == .asked { self.tell("Couldn't check for updates.", c.problem) }
                return
            }
            let version = words.count > 1 ? words[1] : ""
            if kind == "current" {               // "current THIS NEWEST"
                AppDelegate.availableUpdate = nil
                let newest = words.count > 2 ? words[2] : version
                if when == .asked {
                    self.tell("Portalistic is up to date.", newest == version
                        ? "You have \(version), the newest release."
                        : "You have \(version); the newest release is \(newest).")
                }
                return
            }
            let replacing = kind == "replace"     // this copy's version isn't a release any more
            AppDelegate.availableUpdate = version
            let notes = words.count > 2 ? words[2] : ""
            let skipped = UserDefaults.standard.string(forKey: AppDelegate.skippedUpdateKey) == version
            switch when {
            case .asked:
                self.offerUpdate(version, notes: notes, replacing: replacing)
            case .atLaunch:
                if !skipped { self.offerUpdate(version, notes: notes, replacing: replacing) }
            case .daily:
                if !skipped {
                    self.noticeView.show(problem: false, title: "Portalistic \(version) is available",
                                         detail: "Portalistic > Update to \(version)… installs it; Steam keeps running.",
                                         seconds: 12)
                }
            }
        }
        guard c.start() else {
            if when == .asked { tell("Couldn't run the bottle command.", BottleCommand.script ?? "") }
            return
        }
        quietCommands.removeAll { !$0.running }
        quietCommands.append(c)
    }

    /// Update / Later / What's New, on the window (or on its own if the window isn't up).
    /// replacing: this copy's version was withdrawn (or renumbered), so the newest release replaces
    /// it even if its number is lower.
    func offerUpdate(_ version: String, notes: String, replacing: Bool = false) {
        guard !AppDelegate.offeringUpdate else { return }
        AppDelegate.offeringUpdate = true
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let alert = NSAlert()
        alert.messageText = replacing ? "Portalistic \(version) is the current release" : "Portalistic \(version) is available"
        alert.informativeText = (replacing ? "You have \(current), which isn't a release any more. " : "You have \(current). ")
            + "Updating downloads \(version), replaces the app and opens it again, in about a minute. "
            + "Steam and any game keep running in the VM."
        alert.addButton(withTitle: "Update")
        alert.addButton(withTitle: "Later")
        if URL(string: notes) != nil { alert.addButton(withTitle: "What's New") }
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't remind me about \(version)"
        let answered: (NSApplication.ModalResponse) -> Void = { [weak self] answer in
            AppDelegate.offeringUpdate = false
            if alert.suppressionButton?.state == .on {
                UserDefaults.standard.set(version, forKey: AppDelegate.skippedUpdateKey)
            }
            switch answer {
            case .alertFirstButtonReturn:
                self?.installUpdate()
            case .alertThirdButtonReturn:
                if let u = URL(string: notes) { NSWorkspace.shared.open(u) }
            default:
                break
            }
        }
        if let w = window, w.isVisible, w.attachedSheet == nil {
            view?.releaseMouse()                 // (the pointer may be captured by the picture)
            alert.beginSheetModal(for: w, completionHandler: answered)
        } else {
            answered(alert.runModal())
        }
    }

    func installUpdate() {
        activity.run("Updating Portalistic", ["app-update", "install"], log: "app-update") { [weak self] code, c in
            guard let self = self else { return }
            guard code == 0 else {
                self.tell("Portalistic wasn't updated.", c.problem)
                return
            }
            AppDelegate.availableUpdate = nil
            self.openNewCopy()
        }
    }

    /// Opens the app's new copy, which closes this one as it starts, and quits without asking.
    func openNewCopy() {
        leaving = true
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { [weak self] _, error in
            DispatchQueue.main.async {
                if let error = error {
                    self?.leaving = false
                    self?.tell("Portalistic was updated but didn't open again.",
                               error.localizedDescription + " Quit it and open it from the Applications folder.")
                } else {
                    NSApp.terminate(nil)
                }
            }
        }
    }
}
