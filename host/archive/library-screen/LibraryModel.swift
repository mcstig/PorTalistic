// Portalistic — the Library's data: the installed games from `bottle library --copy`.

import AppKit
import Combine

/// One installed game, as guest/bottle-library describes it (`bottle library --copy` puts the
/// list and the covers in ~/Library/Caches/Portalistic/library).
struct Game: Decodable, Identifiable, Hashable {
    let appid: String
    let name: String
    let state: String          // installed, update, updating, paused, incomplete
    let size: Int64
    let lastPlayed: Int        // unix time, 0 = never
    let playtime: Int          // minutes
    let cover: String?         // file in covers/
    let coverKind: String?     // tall (600x900) or wide (header)
    var id: String { appid }
}

private struct LibraryFile: Decodable {
    let games: [Game]
    let running: String?       // the game Steam is running, when it said so
}

final class LibraryModel: ObservableObject {
    enum Sort: String, CaseIterable { case recent = "Recent", name = "A–Z" }

    @Published var games: [Game] = []
    @Published var running: String?
    @Published var search = ""
    @Published var sort: Sort = .recent
    @Published var reading = false               // bottle library --copy running
    @Published var needsUpdate = false           // the VM has no bottle-library yet
    @Published var message: String?              // the last read failed: why
    var onPlay: ((Game) -> Void)?
    var onOpen: ((String) -> Void)?              // a steam:// link
    var onRefresh: (() -> Void)?
    var onShowSteam: (() -> Void)?
    var onUpdate: (() -> Void)?
    private var images: [String: (image: NSImage, time: Date)] = [:]   // covers, with their file's time
    private static let ago: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()
    let dir: URL

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Caches")
        dir = caches.appendingPathComponent("Portalistic/library")
        load()
    }

    /// The list and covers last copied from the VM; false if there's no list or it doesn't read.
    @discardableResult func load() -> Bool {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("library.json")),
              let file = try? JSONDecoder().decode(LibraryFile.self, from: data) else { return false }
        // Covers already loaded stay, unless the file is a different one now (Steam got a new one).
        var kept: [String: (image: NSImage, time: Date)] = [:]
        for g in file.games {
            if let old = images[g.appid], let t = coverTime(g), t == old.time { kept[g.appid] = old }
        }
        images = kept
        games = file.games
        running = file.running
        return true
    }

    private func coverFile(_ g: Game) -> URL? {
        g.cover.map { dir.appendingPathComponent("covers").appendingPathComponent($0) }
    }

    private func coverTime(_ g: Game) -> Date? {
        guard let f = coverFile(g) else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: f.path))?[.modificationDate] as? Date
    }

    func image(for g: Game) -> NSImage? {
        if let c = images[g.appid] { return c.image }
        guard let f = coverFile(g), let img = NSImage(contentsOf: f) else { return nil }
        images[g.appid] = (img, coverTime(g) ?? .distantPast)
        return img
    }

    /// Steam's own picture of a game, when Steam hasn't cached one in the VM yet.
    func storeCoverURL(_ g: Game) -> URL? {
        URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(g.appid)/library_600x900_2x.jpg")
    }

    var shown: [Game] {
        let q = search.trimmingCharacters(in: .whitespaces)
        let list = q.isEmpty ? games : games.filter { $0.name.localizedCaseInsensitiveContains(q) }
        switch sort {
        case .recent:
            return list.sorted {
                $0.lastPlayed != $1.lastPlayed ? $0.lastPlayed > $1.lastPlayed
                    : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        case .name:
            return list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    /// The game at the top: the one running, else the one played last (not while searching).
    var featured: Game? {
        guard search.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        if let r = running, let g = games.first(where: { $0.appid == r }) { return g }
        return games.filter { $0.lastPlayed > 0 }.max { $0.lastPlayed < $1.lastPlayed } ?? games.first
    }

    func isRunning(_ g: Game) -> Bool { g.appid == running }

    /// Running, or not ready to play (Steam is updating it...): nil when it's simply there.
    func status(_ g: Game) -> String? {
        if isRunning(g) { return "Playing now" }
        switch g.state {
        case "updating": return "Updating…"
        case "paused": return "Update paused"
        case "update": return "Update queued"
        case "incomplete": return "Not fully installed"
        default: return nil
        }
    }

    func played(_ g: Game) -> String {
        guard g.lastPlayed > 0 else { return "Not played yet" }
        let d = Date(timeIntervalSince1970: TimeInterval(g.lastPlayed))
        if Calendar.current.isDateInToday(d) { return "Played today" }
        if Calendar.current.isDateInYesterday(d) { return "Played yesterday" }
        return "Played " + LibraryModel.ago.localizedString(for: d, relativeTo: Date())
    }

    func playtime(_ g: Game) -> String? {
        guard g.playtime > 0 else { return nil }
        let h = g.playtime / 60, m = g.playtime % 60
        if h == 0 { return m == 1 ? "1 minute in total" : "\(m) minutes in total" }
        if m == 0 { return h == 1 ? "1 hour in total" : "\(h) hours in total" }
        return "\(h) h \(m) min in total"
    }
}
