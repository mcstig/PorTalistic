// Portalistic — installing the app into Applications, and uninstalling it.
//
// Install. A copy opened from anywhere but an Applications folder (Downloads, a disk image, the
// Desktop) offers, as it starts, to move itself to /Applications (~/Applications if the user can't
// write there). It copies itself, checks the copy (its signature, then Gatekeeper's verdict, after
// which the download's quarantine mark goes, so the copy isn't run from a random read-only place),
// opens the copy and quits. The copy is told where it came from and moves that one to the Trash.
// Portalistic > Move to Applications… does the same later. A copy built from the kit or by Xcode
// stays where it is.
//
// Uninstall. Portalistic > Uninstall Portalistic… asks `bottle uninstall --list` what there is to
// delete and says so, then runs `bottle uninstall --yes` (the VM, and Portalistic's folders: see
// host/bottle), moves the game folders to the Trash if the box was ticked, forgets the app's own
// settings and moves the app to the Trash.
//
// Tests (host/tests/mac-installapp*.sh) run a packaged copy with PORTALISTIC_SELFTEST=install,
// installed or uninstall, a made-up Applications folder and Trash, and a log file. Nothing here
// reads those variables otherwise.

import AppKit

/// Where the app is, and what moving or deleting it takes.
enum Installation {
    static let env = ProcessInfo.processInfo.environment
    static let dontOfferKey = "DontOfferToInstall"
    static let movedFromFlag = "--moved-from"
    static let justInstalledFlag = "--just-installed"

    struct Failure: Error { let why: String }

    /// One line of `bottle uninstall --list`.
    struct Row {
        let kind: String            // system, data or games
        let kilobytes: Int64
        let path: String
        let what: String
    }

    static var home: String {
        if let h = env["HOME"], h.hasPrefix("/"), h.count > 1 { return h }
        return NSHomeDirectory()
    }

    static func rows(from lines: [String]) -> [Row] {
        return lines.compactMap { line in
            let f = line.components(separatedBy: "\t")
            guard f.count >= 4, ["system", "data", "games"].contains(f[0]), f[2].hasPrefix("/") else { return nil }
            return Row(kind: f[0], kilobytes: Int64(f[1]) ?? 0, path: f[2], what: f[3...].joined(separator: "\t"))
        }
    }

    static func sizeText(_ kilobytes: Int64) -> String {
        return ByteCountFormatter.string(fromByteCount: kilobytes * 1024, countStyle: .file)
    }

    static func shortPath(_ path: String) -> String {
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    // MARK: where the app is

    /// The Applications folders: the Mac's and the user's (a made-up one in tests).
    static var applicationsFolders: [String] {
        if let d = env["PORTALISTIC_APPLICATIONS_DIR"], !d.isEmpty { return [d] }
        return ["/Applications", home + "/Applications"]
    }

    static func isInApplications(_ url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().path
        return applicationsFolders.contains { path.hasPrefix(URL(fileURLWithPath: $0).resolvingSymlinksInPath().path + "/") }
    }

    /// Copies built from the kit (not packaged) or by Xcode, and the packaging folder's own, stay where they are.
    static func isDevelopmentCopy(_ url: URL) -> Bool {
        let p = url.path
        return !BottleCommand.isPackaged || p.contains("/Library/Caches/Portalistic/") || p.contains("/DerivedData/")
    }

    /// A downloaded app that is run from where it was downloaded is run from a read-only copy macOS makes
    /// of it under a random name ("App Translocation").
    static func isTranslocated(_ url: URL) -> Bool { return url.path.contains("/AppTranslocation/") }

    /// Where a translocated app really is (macOS says; the symbol is looked up so a macOS without it just
    /// gives the same URL back).
    static func untranslocated(_ url: URL) -> URL {
        guard isTranslocated(url),
              let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let symbol = dlsym(handle, "SecTranslocateCreateOriginalPathForURL") else { return url }
        typealias Original = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        let original = unsafeBitCast(symbol, to: Original.self)
        var error: Unmanaged<CFError>?
        guard let result = original(url as CFURL, &error) else {
            error?.release()
            return url
        }
        return result.takeRetainedValue() as URL
    }

    static var canOfferMove: Bool {
        let me = Bundle.main.bundleURL
        return BottleCommand.isPackaged && !isDevelopmentCopy(me) && !isInApplications(me)
    }

    /// The Applications folder the copy goes to: the Mac's if the user can write there, else their own.
    static func destinationFolder() -> String? {
        let fm = FileManager.default
        if let d = env["PORTALISTIC_APPLICATIONS_DIR"], !d.isEmpty {
            try? fm.createDirectory(atPath: d, withIntermediateDirectories: true)
            return d
        }
        if fm.isWritableFile(atPath: "/Applications") { return "/Applications" }
        let mine = home + "/Applications"
        try? fm.createDirectory(atPath: mine, withIntermediateDirectories: true)
        return fm.isWritableFile(atPath: mine) ? mine : nil
    }

    static func bundleInfo(at path: String) -> (id: String, version: String)? {
        guard let b = Bundle(path: path), let id = b.bundleIdentifier else { return nil }
        return (id, b.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0")
    }

    /// Dotted version numbers: 0.7.0.10 is newer than 0.7.0.9.
    static func versionNewer(_ a: String, than b: String) -> Bool {
        func parts(_ v: String) -> [Int] { return v.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 } }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    // MARK: doing it

    @discardableResult
    static func run(_ tool: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    /// To the Trash (so it can be put back); in tests, to a folder.
    static func trash(_ url: URL) -> Bool {
        let fm = FileManager.default
        if let dir = env["PORTALISTIC_TRASH_DIR"], !dir.isEmpty {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            var name = url.lastPathComponent, n = 1
            while fm.fileExists(atPath: dir + "/" + name) { n += 1; name = "\(n)-" + url.lastPathComponent }
            return (try? fm.moveItem(atPath: url.path, toPath: dir + "/" + name)) != nil
        }
        var result: NSURL?
        return (try? fm.trashItem(at: url, resultingItemURL: &result)) != nil
    }

    /// Copies the app into `folder` as Portalistic.app, checks the copy, and puts it in place (an older
    /// Portalistic.app there goes to the Trash first). Nothing is left behind if a step fails.
    static func copyApp(from source: URL, into folder: String, log: @escaping (String) -> Void = { _ in }) throws -> URL {
        let fm = FileManager.default
        let target = folder + "/Portalistic.app"
        let temp = folder + "/.Portalistic-copying.app"
        func failed(_ why: String) -> Failure {
            log("failed: \(why)")
            do { try fm.removeItem(atPath: temp) } catch { log("leftover \(temp) not removed: \(error.localizedDescription)") }
            return Failure(why: why)
        }
        log("copy \(source.path) -> \(temp)")
        if fm.fileExists(atPath: temp) {
            do { try fm.removeItem(atPath: temp); log("old \(temp) removed") } catch { log("old \(temp) not removed: \(error.localizedDescription)") }
        }
        // The copy is made without the source's extended attributes: a folder that iCloud or another sync
        // service looks after (the Desktop, say) leaves marks on the app that make `codesign --strict` fail
        // ("detritus not allowed"). The download's quarantine mark is the one that matters, so it is put back.
        let mark = run("/usr/bin/xattr", ["-p", "com.apple.quarantine", source.path])
        let copied = run("/usr/bin/ditto", ["--norsrc", "--noextattr", source.path, temp])
        log("ditto: \(copied.status) \(copied.output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))")
        guard copied.status == 0 else {
            throw failed("The copy didn't work (\(copied.output.trimmingCharacters(in: .whitespacesAndNewlines))).")
        }
        let markText = mark.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if mark.status == 0, !markText.isEmpty {
            run("/usr/bin/xattr", ["-w", "com.apple.quarantine", markText, temp])
        }
        let signed = run("/usr/bin/codesign", ["--verify", "--deep", "--strict", temp])
        log("codesign: \(signed.status) \(signed.output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))")
        guard signed.status == 0 else {
            throw failed("The copy's signature doesn't check out, so it wasn't kept.")
        }
        // Gatekeeper accepts a notarized copy; the mark the download left on it can go then. (One it
        // doesn't accept keeps the mark: it is what the user already opened, nothing more.)
        let policy = run("/usr/sbin/spctl", ["-a", "-t", "exec", temp])
        log("spctl: \(policy.status) \(policy.output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))")
        if policy.status == 0 {
            run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", temp])
        }
        if fm.fileExists(atPath: target) {
            let gone = trash(URL(fileURLWithPath: target))
            log("older \(target) to the Trash: \(gone)")
            if !gone { throw failed("The Portalistic in \(folder) couldn't be replaced.") }
        }
        do { try fm.moveItem(atPath: temp, toPath: target) } catch {
            throw failed("It couldn't be put in place (\(error.localizedDescription)).")
        }
        log("in place: \(target)")
        return URL(fileURLWithPath: target)
    }

    /// The app's own settings (the window sizes and so on) and its saved window state.
    static func forgetSettings() {
        let fm = FileManager.default
        for id in [Bundle.main.bundleIdentifier ?? "", AppDelegate.legacyBundleID] where !id.isEmpty {
            UserDefaults.standard.removePersistentDomain(forName: id)
            try? fm.removeItem(atPath: home + "/Library/Saved Application State/\(id).savedState")
            try? fm.removeItem(atPath: home + "/Library/Preferences/\(id).plist")
        }
        UserDefaults.standard.synchronize()
    }

    /// A copy running on a background thread, for the main thread to wait for.
    final class Outcome {
        private let lock = NSLock()
        private var value: Result<URL, Failure>?
        func set(_ v: Result<URL, Failure>) { lock.lock(); value = v; lock.unlock() }
        var result: Result<URL, Failure>? { lock.lock(); defer { lock.unlock() }; return value }
    }

    static func workingPanel(_ text: String) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 90), styleMask: [.titled],
                            backing: .buffered, defer: false)
        panel.title = "Portalistic"
        let label = NSTextField(labelWithString: text)
        label.frame = NSRect(x: 20, y: 48, width: 320, height: 20)
        let bar = NSProgressIndicator(frame: NSRect(x: 20, y: 22, width: 320, height: 12))
        bar.style = .bar
        bar.isIndeterminate = true
        bar.startAnimation(nil)
        panel.contentView?.addSubview(label)
        panel.contentView?.addSubview(bar)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        return panel
    }
}

extension AppDelegate {
    // MARK: tests

    var inSelfTest: Bool { return Installation.env["PORTALISTIC_SELFTEST"] != nil }

    /// What installing does, step by step: the self-test's log, else app-install.log next to the
    /// app's other logs (~/Library/Logs/Portalistic for a packaged app; Oct 23: so a move to
    /// Applications that goes wrong says where).
    func installLog(_ text: String) {
        var path = Installation.env["PORTALISTIC_SELFTEST_LOG"] ?? ""
        if path.isEmpty {
            path = BottleCommand.logDir + "/app-install.log"
            try? FileManager.default.createDirectory(atPath: BottleCommand.logDir, withIntermediateDirectories: true)
        }
        let stamp = ISO8601DateFormatter().string(from: Date())
        guard let data = (stamp + " " + text + "\n").data(using: .utf8) else { return }
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile()
            h.write(data)
            h.closeFile()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    /// A message for the user; in a test, a line in its log.
    func installNotice(_ title: String, _ detail: String) {
        installLog("notice: \(title) \(detail)")
        if !inSelfTest { tell(title, detail) }
    }

    /// What a test run does instead of starting up. install: a copy outside Applications offers to move
    /// (answered by PORTALISTIC_INSTALL_ANSWER); installed: the copy that took over; uninstall: the
    /// whole uninstall (the game folders too if PORTALISTIC_SELFTEST_GAMES=1).
    func runSelfTest(_ mode: String) {
        installLog("selftest \(mode) from \(Bundle.main.bundlePath)")
        switch mode {
        case "install":
            let handedOver = offerInstall()
            installLog("handed over: \(handedOver)")
            if !handedOver { NSApp.terminate(nil) }
        case "installed":
            finishMove()
            installLog("running from \(Bundle.main.bundlePath)")
            NSApp.terminate(nil)
        case "uninstall":
            // deletes things: only ever against a made-up home folder
            guard Installation.home.hasPrefix("/tmp/") || Installation.home.hasPrefix("/private/tmp/") else {
                installLog("refused: \(Installation.home) isn't a test home folder")
                NSApp.terminate(nil)
                return
            }
            uninstallPortalistic(nil)
        default:
            NSApp.terminate(nil)
        }
    }

    // MARK: installing

    /// At launch: a copy outside Applications offers to move there. True when the copy in
    /// Applications is taking over, so starting up goes no further.
    func offerInstall() -> Bool {
        let me = Bundle.main.bundleURL
        guard BottleCommand.isPackaged, !Installation.isDevelopmentCopy(me), !Installation.isInApplications(me),
              !CommandLine.arguments.contains(Installation.justInstalledFlag) else { return false }
        if Installation.env["PORTALISTIC_INSTALL_ANSWER"] == nil, UserDefaults.standard.bool(forKey: Installation.dontOfferKey) {
            return false
        }
        return moveToApplications(offered: true)
    }

    @objc func moveToApplicationsMenu(_ sender: Any?) { _ = moveToApplications(offered: false) }

    /// Copies the app into Applications and opens the copy. True when that copy is taking over.
    func moveToApplications(offered: Bool) -> Bool {
        installing = true
        defer { installing = false }
        let me = Bundle.main.bundleURL
        let myID = Bundle.main.bundleIdentifier ?? ""
        let myVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        installLog("move to Applications: from \(me.path) (translocated: \(Installation.isTranslocated(me))), version \(myVersion), offered: \(offered)")
        guard let folder = Installation.destinationFolder() else {
            installLog("no writable Applications folder")
            installNotice("Portalistic can't copy itself to Applications.",
                          "You can't write to /Applications or ~/Applications. Drag Portalistic to the Applications folder yourself.")
            return false
        }
        let target = URL(fileURLWithPath: folder + "/Portalistic.app")
        var already: String?                     // the version in Applications, when it is this app and not older
        if let there = Installation.bundleInfo(at: target.path) {
            guard there.id == myID else {
                installLog("another app with id \(there.id) is at \(target.path)")
                installNotice("There's another app called Portalistic in \(folder).", "Move it away, then open this copy again.")
                return false
            }
            if !Installation.versionNewer(myVersion, than: there.version) { already = there.version }
        }
        installLog("into \(folder); there already: \(already ?? "nothing")")
        guard askToMove(into: folder, already: already, offered: offered) else { installLog("answer: not now"); return false }
        installLog("answer: move")
        var movedFrom: URL?
        if already == nil {
            let panel = inSelfTest ? nil : Installation.workingPanel("Moving Portalistic to \(Installation.shortPath(folder))…")
            let outcome = Installation.Outcome()
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let copy = try Installation.copyApp(from: me, into: folder) { [weak self] line in
                        DispatchQueue.main.async { self?.installLog("  " + line) }
                    }
                    outcome.set(.success(copy))
                } catch let f as Installation.Failure {
                    outcome.set(.failure(f))
                } catch {
                    outcome.set(.failure(Installation.Failure(why: error.localizedDescription)))
                }
            }
            while outcome.result == nil { RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05)) }
            panel?.orderOut(nil)
            if case .failure(let f)? = outcome.result {
                installNotice("Portalistic wasn't moved to Applications.", f.why + " It carries on from where it is.")
                return false
            }
            let origin = Installation.untranslocated(me)
            if !Installation.isTranslocated(origin) { movedFrom = origin }
            installLog("copied; the original is \(origin.path)")
        }
        openCopy(at: target, movedFrom: movedFrom)
        return true
    }

    private func askToMove(into folder: String, already: String?, offered: Bool) -> Bool {
        if let answer = Installation.env["PORTALISTIC_INSTALL_ANSWER"] { return answer == "move" }
        let alert = NSAlert()
        let place = folder == "/Applications" ? "Applications" : Installation.shortPath(folder)
        if let v = already {
            alert.messageText = "Portalistic \(v) is already in \(place)"
            alert.informativeText = "Open that one instead? This copy stays where it is."
            alert.addButton(withTitle: "Open That One")
        } else {
            alert.messageText = "Move Portalistic to your Applications folder?"
            alert.informativeText = "From there it updates itself, and Launchpad and Spotlight find it. "
                + "Portalistic copies itself to \(place), opens the copy and moves this one to the Trash."
            alert.addButton(withTitle: "Move to Applications")
        }
        alert.addButton(withTitle: "Not Now")
        if offered {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Don't ask again"
        }
        if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        let answer = alert.runModal()
        if offered, alert.suppressionButton?.state == .on { UserDefaults.standard.set(true, forKey: Installation.dontOfferKey) }
        return answer == .alertFirstButtonReturn
    }

    /// Opens the copy in Applications, which closes this one as it starts, and quits without asking.
    private func openCopy(at url: URL, movedFrom: URL?) {
        leaving = true
        let config = NSWorkspace.OpenConfiguration()
        let id = Bundle.main.bundleIdentifier ?? ""
        let there = url.resolvingSymlinksInPath().path
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: id).contains {
            $0.bundleURL?.resolvingSymlinksInPath().path == there
        }
        config.createsNewApplicationInstance = !running
        installLog("opening \(url.path) (a copy from there runs already: \(running))")
        config.arguments = [Installation.justInstalledFlag] + (movedFrom.map { [Installation.movedFromFlag, $0.path] } ?? [])
        var environment = Installation.env.filter { $0.key.hasPrefix("PORTALISTIC_") }
        if environment["PORTALISTIC_SELFTEST"] == "install" { environment["PORTALISTIC_SELFTEST"] = "installed" }
        config.environment = environment
        NSWorkspace.shared.openApplication(at: url, configuration: config) { [weak self] _, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let error = error {
                    self.leaving = false
                    self.installLog("the copy didn't open: \(error.localizedDescription)")
                    self.installNotice("Portalistic is in Applications but didn't open.", error.localizedDescription + " Open it from there.")
                } else {
                    self.installLog("opened \(url.path); this copy quits")
                    NSApp.terminate(nil)
                }
            }
        }
    }

    /// The copy that was just moved to Applications: the one it came from goes to the Trash.
    func finishMove() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: Installation.movedFromFlag), i + 1 < args.count else { return }
        let old = URL(fileURLWithPath: args[i + 1])
        guard old.pathExtension == "app", old.resolvingSymlinksInPath().path != Bundle.main.bundleURL.resolvingSymlinksInPath().path,
              !Installation.isTranslocated(old),
              Installation.bundleInfo(at: old.path)?.id == Bundle.main.bundleIdentifier,
              FileManager.default.isDeletableFile(atPath: old.path) else {
            installLog("old copy not moved to the Trash")
            return
        }
        installLog("old copy moved to the Trash: \(Installation.trash(old))")
    }

    // MARK: uninstalling

    @objc func uninstallPortalistic(_ sender: Any?) {
        guard !activity.busy else { activity.showWindow(nil); return }
        guard BottleCommand.isPackaged else {
            tell("This copy of Portalistic can't uninstall itself.",
                 "It was built from the kit: delete the kit folder and ~/Applications/Portalistic.app yourself.")
            return
        }
        let list = BottleCommand(["uninstall", "--list"], log: "uninstall-list")
        list.onExit = { [weak self, unowned list] code in
            guard let self = self else { return }
            guard code == 0 else {
                self.installNotice("Portalistic can't tell what it would delete.", list.problem)
                if self.inSelfTest { NSApp.terminate(nil) }
                return
            }
            self.askToUninstall(Installation.rows(from: list.lines))
        }
        if !list.start() {
            installNotice("Couldn't run Portalistic's helper script.", BottleCommand.script ?? "")
            return
        }
        quietCommands.removeAll { !$0.running }
        quietCommands.append(list)
    }

    private func askToUninstall(_ rows: [Installation.Row]) {
        let games = rows.filter { $0.kind == "games" }
        var tickGames = Installation.env["PORTALISTIC_SELFTEST_GAMES"] == "1"
        if !inSelfTest {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Uninstall Portalistic?"
            var text = "This deletes what Portalistic keeps on this Mac, then moves Portalistic to the Trash. "
                + "Steam and any game that's running quit."
            if let s = rows.first(where: { $0.kind == "system" }) {
                text += "\n\n• The Linux system, \(Installation.sizeText(s.kilobytes)): Steam, your store sign-ins and any game installed on its own disk."
            }
            let data = rows.filter { $0.kind == "data" }
            if !data.isEmpty {
                text += "\n• Settings, logs and downloaded updates, \(Installation.sizeText(data.reduce(0) { $0 + $1.kilobytes }))."
            }
            if !games.isEmpty { text += "\n\nYour game folders stay where they are, unless you tick the box. The Trash keeps them until you empty it." }
            alert.informativeText = text
            var box: NSButton?
            if !games.isEmpty {
                let b = NSButton(checkboxWithTitle: "Also move my game folders to the Trash", target: nil, action: nil)
                let names = NSTextField(wrappingLabelWithString: games.map { "\($0.what): \(Installation.shortPath($0.path))" + ($0.kilobytes > 0 ? " (\(Installation.sizeText($0.kilobytes)) in its game drive)" : "") }.joined(separator: "\n"))
                names.font = .systemFont(ofSize: 11)
                names.textColor = .secondaryLabelColor
                names.preferredMaxLayoutWidth = 340
                let stack = NSStackView(views: [b, names])
                stack.orientation = .vertical
                stack.alignment = .leading
                stack.spacing = 4
                stack.frame = NSRect(x: 0, y: 0, width: 340, height: 24 + 15 * CGFloat(games.count))
                alert.accessoryView = stack
                box = b
            }
            alert.addButton(withTitle: "Uninstall").hasDestructiveAction = true
            alert.addButton(withTitle: "Cancel")
            if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            tickGames = box?.state == .on
        }
        let chosen = tickGames ? games : []
        if inSelfTest {
            let c = BottleCommand(["uninstall", "--yes"], log: "uninstall")
            c.onExit = { [weak self, unowned c] code in
                guard let self = self else { return }
                self.installLog("uninstall command: \(code)")
                if code == 0 { self.finishUninstall(chosen) } else { self.installLog("problem: \(c.problem)"); NSApp.terminate(nil) }
            }
            if !c.start() { installLog("couldn't start"); NSApp.terminate(nil); return }
            quietCommands.append(c)
        } else {
            activity.run("Uninstalling Portalistic", ["uninstall", "--yes"], log: "uninstall") { [weak self] code, c in
                if code == 0 {
                    self?.finishUninstall(chosen)
                } else {
                    self?.tell("Portalistic wasn't fully uninstalled.", c.problem)
                }
            }
        }
    }

    /// After the bottle command: the game folders (if asked) and the app go to the Trash, the app's
    /// settings are forgotten, and the app quits for good.
    private func finishUninstall(_ games: [Installation.Row]) {
        var kept: [String] = []
        let fm = FileManager.default
        for g in games {
            let url = URL(fileURLWithPath: g.path)
            let isLink = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink ?? false
            // only a folder Portalistic made (it has its marker), and not through a link
            if !isLink, fm.fileExists(atPath: g.path + "/.portalistic-library"), Installation.trash(url) {
                installLog("game folder moved to the Trash: \(g.path)")
            } else {
                kept.append(g.what)
            }
        }
        let appURL = Installation.untranslocated(Bundle.main.bundleURL)
        let appTrashed = !Installation.isTranslocated(appURL) && Installation.trash(appURL)
        installLog("app moved to the Trash: \(appTrashed)")
        var detail = "Its Linux system, settings and logs are deleted."
        if !games.isEmpty {
            detail += kept.isEmpty ? " Your game folders are in the Trash."
                : " These game folders were left where they are: " + kept.joined(separator: ", ") + "."
        }
        if !appTrashed { detail += " Drag Portalistic to the Trash to finish." }
        installNotice("Portalistic is uninstalled.", detail)
        if !inSelfTest { Installation.forgetSettings() }
        leaving = true
        exit(0)         // (quitting the usual way could save a window's size again)
    }
}
