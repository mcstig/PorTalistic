// Portalistic — Stores > GOG Games… and Epic Games…: sign in to the store, see the games you own,
// install and remove them. The VM downloads a game (`bottle gog install`, `bottle epic install`;
// guest/bottle-stores) and Steam lists it as a non-Steam game that runs through Proton like the
// Steam ones, in Big Picture too (collection “GOG” or “Epic Games”). The windows' looks are in
// GOGViews.swift; this runs the bottle commands behind them.

import AppKit

extension AppDelegate {
    @objc func showGOGGames(_ sender: Any?) {
        StoreWindow.gog.open(app: self)
    }

    @objc func showEpicGames(_ sender: Any?) {
        StoreWindow.epic.open(app: self)
    }
}

/// A store's window (GOG Games, Epic Games). One of each for the whole run: a download carries on
/// when it's closed, and opening it again shows where it is.
final class StoreWindow: NSWindowController {
    static let gog = StoreWindow(.gog)
    static let epic = StoreWindow(.epic)

    private let store: StoreInfo
    private weak var app: AppDelegate?
    private let content: StoreContentView
    private var current: BottleCommand?
    private var games: [StoreGame] = []
    private var folders: [StoreFolder] = []
    private var userName = ""

    init(_ info: StoreInfo) {
        store = info
        content = StoreContentView(frame: NSRect(x: 0, y: 0, width: 960, height: 700), store: info)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 700),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = info.windowTitle
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 820, height: 480)
        super.init(window: w)
        w.contentView = content
        if !w.setFrameUsingName(info.frameName) { w.center() }
        w.setFrameAutosaveName(info.frameName)
        wire()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func wire() {
        let loginURL = store.loginURL
        content.onOpenLogin = { NSWorkspace.shared.open(loginURL) }
        content.onSignIn = { [weak self] text in self?.signIn(text) }
        content.onSignOut = { [weak self] in self?.signOut() }
        content.onRefresh = { [weak self] in self?.loadGames(refresh: true) }
        content.onRetry = { [weak self] in self?.reload() }
        content.onInstall = { [weak self] g, f in self?.install(g, f) }
        content.onRemove = { [weak self] g in self?.remove(g) }
    }

    // MARK: running bottle commands

    /// One command at a time; `done` gets the command and whether it succeeded.
    @discardableResult
    private func run(_ args: [String], log: String, done: @escaping (BottleCommand, Bool) -> Void) -> Bool {
        return runStreaming(args, log: log, onLine: { _ in }, done: done)
    }

    /// The same, with each line of output as it comes.
    @discardableResult
    private func runStreaming(_ args: [String], log: String, onLine: @escaping (String) -> Void,
                              done: @escaping (BottleCommand, Bool) -> Void) -> Bool {
        guard current?.running != true else { return false }
        let c = BottleCommand(args, log: "\(store.id)-\(log)")
        c.onLine = onLine
        c.onExit = { [weak self, unowned c] code in
            self?.current = nil
            self?.content.locked = false
            done(c, code == 0)
        }
        guard c.start() else {
            showStopped()
            return false
        }
        current = c
        content.locked = true
        return true
    }

    private static func json(_ lines: [String]) -> [String: Any]? {
        for l in lines where l.hasPrefix("{") {
            if let d = l.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { return o }
        }
        return nil
    }

    private static func games(_ rows: [[String: Any]]) -> [StoreGame] {
        return rows.compactMap { r in
            guard let id = r["id"] as? String, let t = r["title"] as? String else { return nil }
            return StoreGame(id: id, title: t, installed: (r["installed"] as? Bool) ?? false,
                             size: (r["size"] as? NSNumber)?.int64Value ?? 0, image: (r["image"] as? String) ?? "",
                             update: (r["update"] as? Bool) ?? false,
                             year: (r["year"] as? NSNumber)?.intValue ?? 0)
        }
    }

    private func showStopped() {
        content.showMessage("The VM isn't running",
                            "\(store.name) games are downloaded inside it. Choose Steam > Start the VM, then try again.")
    }

    // MARK: showing and loading

    func open(app: AppDelegate) {
        self.app = app
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        if current?.running != true { reload() }
    }

    private func reload() {
        guard let app = app, app.view.connected else { showStopped(); return }
        content.showLoading("Asking \(store.name)…")
        run([store.id, "status", "--json"], log: "status") { [weak self] c, ok in
            guard let self = self else { return }
            guard ok, let st = StoreWindow.json(c.lines) else {
                self.content.showMessage("Couldn't ask the bottle about \(self.store.name)", c.problem)
                return
            }
            self.userName = st["user"] as? String ?? ""
            if (st["downloader"] as? Bool) == false {
                self.content.showMessage("\(self.store.name)'s downloader isn't in the bottle yet",
                                         "Choose Steam > Update the VM, then open this window again.")
                return
            }
            if (st["signedIn"] as? Bool) == true { self.loadGames(refresh: false) } else { self.content.showSignIn() }
        }
    }

    private func loadGames(refresh: Bool) {
        content.showLoading((refresh ? "Asking \(store.name) for your games…" : "Loading your games…") + store.slowFirstLoad)
        var args = [store.id, "list", "--json"]
        if refresh { args.append("--refresh") }
        run(args, log: "list") { [weak self] c, ok in
            guard let self = self else { return }
            guard ok, let d = StoreWindow.json(c.lines), let rows = d["games"] as? [[String: Any]] else {
                if c.problem.lowercased().contains("not signed in") || c.problem.lowercased().contains("sign-in expired") {
                    self.content.showSignIn()
                } else {
                    self.content.showMessage("Couldn't get your \(self.store.name) games",
                                             c.problem.isEmpty ? "\(self.store.name) didn't answer." : c.problem)
                }
                return
            }
            self.games = StoreWindow.games(rows)
            self.loadFolders()
        }
    }

    private func loadFolders() {
        run([store.id, "folders", "--json"], log: "folders") { [weak self] c, ok in
            guard let self = self else { return }
            let rows = (ok ? StoreWindow.json(c.lines)?["folders"] as? [[String: Any]] : nil) ?? []
            self.folders = rows.compactMap { r in
                guard let n = r["name"] as? String, let l = r["label"] as? String else { return nil }
                return StoreFolder(name: n, label: l, free: (r["free"] as? NSNumber)?.int64Value ?? 0,
                                   isDefault: (r["default"] as? Bool) ?? false)
            }
            self.content.showLibrary(user: self.userName, games: self.games, folders: self.folders)
        }
    }

    /// After an install or a removal: the games' states again, the window left as it is.
    private func refreshList() {
        run([store.id, "list", "--json"], log: "list") { [weak self] c, ok in
            guard let self = self, ok, let d = StoreWindow.json(c.lines), let rows = d["games"] as? [[String: Any]] else { return }
            self.games = StoreWindow.games(rows)
            self.content.updateGames(self.games)
        }
    }

    // MARK: actions

    private func signIn(_ text: String) {
        guard !text.isEmpty else {
            app?.tell(store.pasteFirst.title, store.pasteFirst.detail)
            return
        }
        run([store.id, "login", text], log: "login") { [weak self] c, ok in
            guard let self = self else { return }
            if ok {
                self.content.clearCode()
                self.reload()
            } else {
                self.app?.tell("\(self.store.name) didn't sign you in", c.problem)
            }
        }
    }

    private func signOut() {
        guard let app = app, app.confirm("Sign out of \(store.name)?",
                                         "Games you installed stay, and keep working. You'll sign in again to install more.", "Sign Out") else { return }
        run([store.id, "logout"], log: "logout") { [weak self] _, _ in self?.reload() }
    }

    private func install(_ g: StoreGame, _ folder: StoreFolder?) {
        guard let app = app else { return }
        guard app.view.connected else { showStopped(); return }
        let verb = g.installed ? "Update" : "Install"
        let place = folder.map { " in “\($0.label)”" } ?? ""
        let what = g.installed
            ? "It asks \(store.name) for a newer version and downloads what changed."
            : "It downloads inside the bottle and goes\(place) under “\(store.folder)”."
        guard app.confirm("\(verb) \(g.title)?",
                          what + " When it's done, Steam restarts to show it (a running game is left alone). "
                          + "It can take a while; you can close this window." + store.installNote, verb) else { return }
        var args = [store.id, "install", g.id]
        if let f = folder { args += ["--folder", f.name] }
        content.setBusy(g.id, progress: 0, text: "Starting…")
        let started = runStreaming(args, log: "install", onLine: { [weak self] line in self?.installLine(line) }) { [weak self] c, ok in
            guard let self = self else { return }
            self.content.setBusy(nil, progress: nil, text: "")
            if ok {
                self.content.setNote(g.id, "Installed. It's in Steam's library, in the “\(self.store.collection)” collection.")
                self.refreshList()
            } else {
                app.tell("Couldn't \(verb.lowercased()) \(g.title)", c.problem)
            }
        }
        if !started { content.setBusy(nil, progress: nil, text: "") }
    }

    private func installLine(_ line: String) {
        if line.hasPrefix("@@progress ") {
            let p = line.split(separator: " ")
            if p.count >= 5, let pct = Double(p[1]) {
                content.setBusyProgress(pct, text: "Downloading, \(Int(pct))%" + StoreWindow.left(String(p[4])))
            }
        } else if !line.isEmpty && !line.hasPrefix("@@") {
            content.setBusyText(readableLine(line))
        }
    }

    /// The downloader's "01:02:03" as ", about 1 h 2 min left".
    private static func left(_ eta: String) -> String {
        let parts = eta.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 3 else { return "" }
        let minutes = parts[0] * 60 + parts[1] + (parts[2] > 30 ? 1 : 0)
        if minutes < 1 { return ", under a minute left" }
        if minutes < 60 { return ", about \(minutes) min left" }
        return ", about \(minutes / 60) h \(minutes % 60) min left"
    }

    private func remove(_ g: StoreGame) {
        guard let app = app else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \(g.title)?"
        alert.informativeText = "Its files are deleted and it leaves Steam's library (Steam restarts to show that; a running game stops it). You can install it again from here."
        let box = NSButton(checkboxWithTitle: "Also delete its saved games and settings", target: nil, action: nil)
        box.sizeToFit()
        alert.accessoryView = box
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var args = [store.id, "remove", g.id]
        if box.state == .on { args.append("--purge") }
        content.setBusy(g.id, progress: nil, text: "Removing…")
        let started = runStreaming(args, log: "remove", onLine: { [weak self] line in
            if !line.isEmpty && !line.hasPrefix("@@") { self?.content.setBusyText(readableLine(line)) }
        }) { [weak self] c, ok in
            guard let self = self else { return }
            self.content.setBusy(nil, progress: nil, text: "")
            if ok {
                self.content.setNote(g.id, "Removed.")
                self.refreshList()
            } else {
                app.tell("Couldn't remove \(g.title)", c.problem)
            }
        }
        if !started { content.setBusy(nil, progress: nil, text: "") }
    }
}
