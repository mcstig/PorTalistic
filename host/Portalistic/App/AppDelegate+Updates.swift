// Portalistic — updating the app from its GitHub releases (`bottle app-update`, in host/bottle).
//
// The packaged app looks a minute after it opens and then once a day. A new version shows as a
// notice over the picture (nothing pops up over a game) and in the app menu, where Check for
// Updates… offers it. Installing it downloads the new copy, checks its signature, swaps it in
// and opens it; the VM, Steam and a game keep running meanwhile.

import AppKit

extension AppDelegate {
    static var availableUpdate: String?          // a newer version GitHub has, once a check found it
    static var offeringUpdate = false            // the update question is on screen
    static let skippedUpdateKey = "SkippedUpdateVersion"

    func scheduleUpdateChecks() {
        guard BottleCommand.isPackaged else { return }
        perform(#selector(checkForUpdatesQuietly), with: nil, afterDelay: 60)
        let t = Timer(timeInterval: 24 * 3600, target: self, selector: #selector(checkForUpdatesQuietly),
                      userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
    }

    @objc func checkForUpdatesQuietly() { checkForUpdates(manual: false) }

    @objc func checkForUpdatesNow(_ sender: Any?) { checkForUpdates(manual: true) }

    func checkForUpdates(manual: Bool) {
        guard BottleCommand.isPackaged else {
            if manual {
                tell("This copy of Portalistic doesn't update itself.",
                     "It was built from the kit: updating the kit rebuilds it.")
            }
            return
        }
        let c = BottleCommand(["app-update", "check"], log: "app-update-check")
        c.onExit = { [weak self, unowned c] code in
            guard let self = self else { return }
            let answer = c.lines.last(where: { $0.hasPrefix("update ") || $0.hasPrefix("current ") }) ?? ""
            let words = answer.split(separator: " ").map(String.init)
            guard code == 0, let kind = words.first else {
                if manual { self.tell("Couldn't check for updates.", c.problem) }
                return
            }
            let version = words.count > 1 ? words[1] : ""
            if kind == "current" {
                AppDelegate.availableUpdate = nil
                if manual { self.tell("Portalistic is up to date.", "\(version) is the newest version.") }
                return
            }
            AppDelegate.availableUpdate = version
            let notes = words.count > 2 ? words[2] : ""
            if manual {
                self.offerUpdate(version, notes: notes)
            } else if UserDefaults.standard.string(forKey: AppDelegate.skippedUpdateKey) != version {
                self.noticeView.show(problem: false, title: "Portalistic \(version) is available",
                                     detail: "Portalistic > Update to \(version)… installs it; Steam keeps running.",
                                     seconds: 12)
            }
        }
        guard c.start() else {
            if manual { tell("Couldn't run the bottle command.", BottleCommand.script ?? "") }
            return
        }
        quietCommands.removeAll { !$0.running }
        quietCommands.append(c)
    }

    func offerUpdate(_ version: String, notes: String) {
        guard !AppDelegate.offeringUpdate else { return }
        AppDelegate.offeringUpdate = true
        defer { AppDelegate.offeringUpdate = false }
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let alert = NSAlert()
        alert.messageText = "Portalistic \(version) is available"
        alert.informativeText = "You have \(current). Updating downloads the new version, replaces the app and opens it "
            + "again, in about a minute. Steam and any game keep running in the VM."
        alert.addButton(withTitle: "Update")
        alert.addButton(withTitle: "Later")
        if URL(string: notes) != nil { alert.addButton(withTitle: "What's New") }
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't remind me about \(version)"
        let answer = alert.runModal()
        if alert.suppressionButton?.state == .on {
            UserDefaults.standard.set(version, forKey: AppDelegate.skippedUpdateKey)
        }
        switch answer {
        case .alertFirstButtonReturn:
            installUpdate()
        case .alertThirdButtonReturn:
            if let u = URL(string: notes) { NSWorkspace.shared.open(u) }
        default:
            break
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
