// Portalistic — the views of the store windows (GOG Games, Epic Games): a grid of covers, an
// install bar under it, and the sign-in, loading and trouble screens. The file keeps the name it
// had when GOG was the only store. What differs between the stores is in StoreInfo. No app logic
// here: AppDelegate+Stores.swift runs the bottle commands and feeds these, and
// host/tests/mac-gogshot.sh draws them with made-up games so the look can be checked without
// signing in to anything.

import AppKit
import ImageIO

struct StoreGame {
    let id: String
    let title: String
    var installed: Bool
    var size: Int64
    /// The store's picture address for it (GOG: the cover's fallback; Epic: the cover); may be empty.
    var image: String
    /// The store has a newer version than the installed one.
    var update = false
    /// The year it came out (0: the store doesn't say).
    var year = 0
}

/// How the grid orders the games. Installed games always come first; this orders each group.
enum StoreSort: Int, CaseIterable {
    case nameAZ, nameZA, newest, oldest

    var title: String {
        switch self {
        case .nameAZ: return "Name, A to Z"
        case .nameZA: return "Name, Z to A"
        case .newest: return "Year, newest first"
        case .oldest: return "Year, oldest first"
        }
    }

    /// Whether `a` goes before `b`. Games without a year go last in both year orders.
    func before(_ a: StoreGame, _ b: StoreGame) -> Bool {
        func byName(_ x: StoreGame, _ y: StoreGame) -> Bool {
            let c = x.title.localizedStandardCompare(y.title)
            return c == .orderedSame ? x.id < y.id : c == .orderedAscending
        }
        switch self {
        case .nameAZ: return byName(a, b)
        case .nameZA: return byName(b, a)
        case .newest, .oldest:
            if a.year != b.year {
                if a.year == 0 { return false }
                if b.year == 0 { return true }
                return self == .newest ? a.year > b.year : a.year < b.year
            }
            return byName(a, b)
        }
    }

    /// `games` as the grid shows them: the installed ones first, each group in this order.
    func arranged(_ games: [StoreGame]) -> [StoreGame] {
        return games.filter { $0.installed }.sorted(by: before) + games.filter { !$0.installed }.sorted(by: before)
    }
}

struct StoreFolder {
    let name: String
    let label: String
    let free: Int64
    let isDefault: Bool
}

enum StoreStyle {
    static let green = NSColor(srgbRed: 0.31, green: 0.78, blue: 0.55, alpha: 1)

    static func rounded(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        if let d = base.fontDescriptor.withDesign(.rounded), let f = NSFont(descriptor: d, size: size) { return f }
        return base
    }

    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}

/// What differs between the stores the window serves: its colour, its words, where its sign-in starts.
struct StoreInfo {
    enum Kind { case gog, epic }

    let kind: Kind
    /// The word after `bottle` in its commands (and in the names of its logs).
    let id: String
    let name: String
    /// The folder inside a game folder that its games go in.
    let folder: String
    /// The Steam collection its games are in.
    let collection: String
    /// The store's colour, lightened a little to read on a dark window.
    let accent: NSColor
    /// The fill of the main button (white text on it).
    let fill: NSColor
    let loginURL: URL
    let loginButton: String
    let steps: [String]
    let codePlaceholder: String
    let pasteFirst: (title: String, detail: String)
    let privacy: String
    let noGames: String
    /// Said in the install question, after what it does.
    let installNote: String
    /// Added to "Loading your games…" (the store's list can take long the first time).
    let slowFirstLoad: String
    let windowTitle: String
    let frameName: String
    let art: StoreArt

    static let gog = StoreInfo(
        kind: .gog, id: "gog", name: "GOG", folder: "GOG Games", collection: "GOG",
        accent: NSColor(srgbRed: 0.64, green: 0.35, blue: 0.76, alpha: 1),
        fill: NSColor(srgbRed: 0.53, green: 0.24, blue: 0.64, alpha: 1),
        loginURL: URL(string: "https://auth.gog.com/auth?client_id=46899977096215655&redirect_uri=https%3A%2F%2Fembed.gog.com%2Fon_login_success%3Forigin%3Dclient&response_type=code&layout=galaxy")!,
        loginButton: "Open GOG Sign-In",
        steps: ["Sign in on GOG's page, in your browser.",
                "GOG then ends on an almost empty page. Copy its whole address from the address bar: it contains “code=”.",
                "Paste it here. The code works once, and only for a minute or so, so do this straight away."],
        codePlaceholder: "Paste the address (or just the code) here",
        pasteFirst: ("Paste GOG's address first",
                     "After you sign in on GOG's page, copy the address of the page you end up on and paste it here."),
        privacy: "Your password never reaches Portalistic. Only the sign-in GOG hands back is kept, inside the bottle.",
        noGames: "No games with a Windows version in your GOG library.",
        installNote: "", slowFirstLoad: "", windowTitle: "GOG Games", frameName: "PortalisticGOGLibrary2",
        art: StoreArt(.gog))

    static let epic = StoreInfo(
        kind: .epic, id: "epic", name: "Epic Games", folder: "Epic Games", collection: "Epic Games",
        accent: NSColor(srgbRed: 0.33, green: 0.62, blue: 0.98, alpha: 1),
        fill: NSColor(srgbRed: 0.0, green: 0.42, blue: 0.86, alpha: 1),
        loginURL: URL(string: "https://www.epicgames.com/id/login?redirectUrl=https%3A//www.epicgames.com/id/api/redirect%3FclientId%3D34a02cf8f4414e29b15921876da36f9a%26responseType%3Dcode")!,
        loginButton: "Open Epic Sign-In",
        steps: ["Sign in on Epic's page, in your browser.",
                "Epic then shows a short line of text that contains “authorizationCode”. Select all of it and copy it.",
                "Paste it here. The code works once, and only for a short while, so do this straight away."],
        codePlaceholder: "Paste Epic's text (or just the code) here",
        pasteFirst: ("Paste Epic's text first",
                     "After you sign in on Epic's page, select all the text it shows, copy it and paste it here."),
        privacy: "Your password never reaches Portalistic. Only the sign-in Epic hands back is kept, inside the bottle.",
        noGames: "No games with a Windows version in your Epic library.",
        installNote: " Games that need anti-cheat software may not start.",
        slowFirstLoad: " The first time can take a minute or two.",
        windowTitle: "Epic Games", frameName: "PortalisticEpicLibrary",
        art: StoreArt(.epic))
}

// MARK: - pictures

private final class StoreDataBox: @unchecked Sendable {
    var data: Data?
}

/// Cover pictures, kept in the Mac's caches folder so each is fetched once. GOG's games database knows
/// each game's vertical cover; Epic's games list gives its address, and the picture comes far bigger
/// than a tile needs, so it is shrunk before it is kept.
final class StoreArt {
    /// For tests: pictures made up instead of fetched.
    var stand: ((StoreGame) -> NSImage?)?
    private let kind: StoreInfo.Kind
    private let memory = NSCache<NSString, NSImage>()
    private let folder: URL
    private let queue = OperationQueue()
    private var waiting: [String: [(NSImage?) -> Void]] = [:]     // main thread only
    private var missed = Set<String>()                             // main thread only

    init(_ kind: StoreInfo.Kind) {
        self.kind = kind
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        folder = base.appendingPathComponent(kind == .gog ? "Portalistic/gog-art" : "Portalistic/epic-art", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        queue.maxConcurrentOperationCount = 6
        queue.qualityOfService = .utility
    }

    /// Calls `done` on the main thread with the cover, or nil when there's none to be had.
    func cover(for game: StoreGame, _ done: @escaping (NSImage?) -> Void) {
        if let s = stand { done(s(game)); return }
        if let m = memory.object(forKey: game.id as NSString) { done(m); return }
        if missed.contains(game.id) { done(nil); return }
        if waiting[game.id] != nil { waiting[game.id]?.append(done); return }
        waiting[game.id] = [done]
        let id = game.id
        let file = folder.appendingPathComponent(id + ".img")
        let kind = self.kind
        let fallback = kind == .gog ? StoreArt.address(game.image) : URL(string: game.image)
        queue.addOperation { [weak self] in
            var image: NSImage?
            if let d = try? Data(contentsOf: file), let i = NSImage(data: d) {
                image = i
            } else {
                var blob: Data?
                switch kind {
                case .gog:
                    blob = StoreArt.fetchCover(id)
                    if blob == nil, let u = fallback { blob = StoreArt.download(u) }
                case .epic:
                    if let u = fallback, let d = StoreArt.download(u) { blob = StoreArt.shrink(d, maxPixel: 520) }
                }
                if let b = blob, let i = NSImage(data: b) {
                    image = i
                    try? b.write(to: file)
                }
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let i = image { self.memory.setObject(i, forKey: id as NSString) } else { self.missed.insert(id) }
                let all = self.waiting.removeValue(forKey: id) ?? []
                for f in all { f(image) }
            }
        }
    }

    /// The fallback: the picture GOG's own games list gives for the game.
    static func address(_ s: String) -> URL? {
        if s.isEmpty { return nil }
        let base = s.hasPrefix("//") ? "https:" + s : s
        return URL(string: base + "_392.jpg")
    }

    static func fetchCover(_ id: String) -> Data? {
        guard let u = URL(string: "https://gamesdb.gog.com/platforms/gog/external_releases/\(id)"),
              let d = download(u),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let g = o["game"] as? [String: Any],
              let c = g["vertical_cover"] as? [String: Any],
              let f = c["url_format"] as? String else { return nil }
        let s = f.replacingOccurrences(of: "{formatter}", with: "").replacingOccurrences(of: "{ext}", with: "jpg")
        guard let pic = URL(string: s) else { return nil }
        return download(pic)
    }

    /// A picture's bytes scaled down to at most `maxPixel` on its long side, as JPEG; nil when it can't be read.
    static func shrink(_ data: Data, maxPixel: Int) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxPixel]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, thumb, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(dst) ? out as Data : nil
    }

    static func download(_ url: URL) -> Data? {
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("Portalistic", forHTTPHeaderField: "User-Agent")
        let box = StoreDataBox()
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { d, r, _ in
            if let h = r as? HTTPURLResponse, h.statusCode == 200 { box.data = d }
            sem.signal()
        }.resume()
        sem.wait()
        return box.data
    }
}

// MARK: - the cover

/// A game's cover, drawn rounded; without a picture, a colour field with the title (the colour
/// follows the title, so a game keeps its own). Installed games carry a small badge and keep their
/// colours; the ones not installed are drawn in black and white. A running download has a dimmed
/// cover with its percentage. Under the mouse the cover pops: it swells a little (with a small
/// overshoot), lifts off the grid on a shadow, and shrinks back when the mouse leaves.
final class StoreCoverView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    var title = "" { didSet { needsDisplay = true } }
    var installed = false { didSet { needsDisplay = true } }
    var progress: Double? { didSet { needsDisplay = true } }      // 0...100
    var selected = false { didSet { needsDisplay = true } }
    var accent = NSColor.systemBlue { didSet { needsDisplay = true } }

    /// The view reaches this far past the cover on every side: room for the pop and the shadow under it.
    static let margin: CGFloat = 20
    /// How much bigger the cover is at full pop (0.07: 7 %).
    private static let popScale: CGFloat = 0.07
    /// 0 at rest, 1 under the mouse (the spring passes 1 for a moment).
    private(set) var lift: CGFloat = 0
    private var liftFrom: CGFloat = 0
    private var liftTo: CGFloat = 0
    private var liftStart: CFTimeInterval = 0
    private var liftTimer: Timer?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    /// The mouse is over the cover (or left it). `animated` false: at once (tests, a recycled cell).
    func setHovered(_ on: Bool, animated: Bool = true) {
        let to: CGFloat = on ? 1 : 0
        guard to != liftTo || (!animated && lift != to) else { return }
        liftTo = to
        liftTimer?.invalidate()
        liftTimer = nil
        if !animated || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            lift = to
            needsDisplay = true
            return
        }
        liftFrom = lift
        liftStart = CACurrentMediaTime()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            self.stepLift()
        }
        RunLoop.main.add(t, forMode: .common)
        liftTimer = t
    }

    private func stepLift() {
        let rising = liftTo > liftFrom
        let t = CGFloat(min(1, (CACurrentMediaTime() - liftStart) / (rising ? 0.30 : 0.18)))
        let k: CGFloat
        if rising {
            let c1: CGFloat = 1.6, c3: CGFloat = 2.6, u = t - 1       // a quick rise that overshoots a little, then settles
            k = 1 + c3 * u * u * u + c1 * u * u
        } else {
            k = 1 - (1 - t) * (1 - t) * (1 - t)                        // eases back
        }
        lift = liftFrom + (liftTo - liftFrom) * k
        needsDisplay = true
        if t >= 1 {
            lift = liftTo
            liftTimer?.invalidate()
            liftTimer = nil
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        // the cover as it rests, then grown by the pop: sideways about its middle, but up rather than down
        // (about a point near its bottom edge), so it doesn't climb over the title under it
        let base = bounds.insetBy(dx: StoreCoverView.margin + 4, dy: StoreCoverView.margin + 4)
        let grow = 1 + StoreCoverView.popScale * lift
        let pivot = base.minY + base.height * 0.85
        let r = NSRect(x: base.midX - base.width * grow / 2, y: pivot - (pivot - base.minY) * grow,
                       width: base.width * grow, height: base.height * grow)
        let shape = NSBezierPath(roundedRect: r, xRadius: 9, yRadius: 9)
        if lift > 0.01 {
            let strength = min(lift, 1)
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.55 * strength)
            shadow.shadowBlurRadius = 12 * strength
            shadow.shadowOffset = NSSize(width: 0, height: -4 * strength)
            NSGraphicsContext.saveGraphicsState()
            shadow.set()
            NSColor.black.setFill()
            shape.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        if let img = image { drawFilled(img, in: r) } else { drawPlaceholder(in: r) }
        if !installed {
            // black and white: gray laid over in the "saturation" blend takes the colour out and keeps the light
            NSColor(white: 0.5, alpha: 1).setFill()
            r.fill(using: .saturation)
        }
        if let p = progress { drawProgress(p, in: r) } else if installed { drawBadge(in: r) }
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(0.10).setStroke()     // a hairline, so a dark cover doesn't melt into the window
        shape.lineWidth = 1
        shape.stroke()
        if selected {
            let ring = NSBezierPath(roundedRect: r.insetBy(dx: -2.5, dy: -2.5), xRadius: 11, yRadius: 11)
            ring.lineWidth = 3
            accent.setStroke()
            ring.stroke()
        }
    }

    private func drawFilled(_ img: NSImage, in r: NSRect) {
        let s = img.size
        guard s.width > 0, s.height > 0 else { return }
        let want = r.width / r.height
        var src = NSRect(origin: .zero, size: s)
        if s.width / s.height > want {
            src.size.width = s.height * want
            src.origin.x = (s.width - src.width) / 2
        } else {
            src.size.height = s.width / want
            src.origin.y = (s.height - src.height) / 2
        }
        NSGraphicsContext.current?.imageInterpolation = .high
        img.draw(in: r, from: src, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    private func drawPlaceholder(in r: NSRect) {
        var seed: UInt32 = 5381
        for u in title.unicodeScalars { seed = (seed &* 33) &+ u.value }
        let hue = CGFloat(seed % 360) / 360
        let top = NSColor(calibratedHue: hue, saturation: 0.42, brightness: 0.50, alpha: 1)
        let bottom = NSColor(calibratedHue: hue, saturation: 0.58, brightness: 0.20, alpha: 1)
        NSGradient(starting: top, ending: bottom)?.draw(in: r, angle: 90)
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byWordWrapping
        let attrs: [NSAttributedString.Key: Any] = [
            .font: StoreStyle.rounded(18, .bold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.92),
            .paragraphStyle: para,
        ]
        let box = r.insetBy(dx: 14, dy: 14)
        let str = NSAttributedString(string: title, attributes: attrs)
        let need = ceil(str.boundingRect(with: NSSize(width: box.width, height: 10_000),
                                         options: [.usesLineFragmentOrigin], context: nil).height)
        let used = min(need, box.height)
        str.draw(with: NSRect(x: box.minX, y: box.midY - used / 2, width: box.width, height: used),
                 options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
    }

    private func drawBadge(in r: NSRect) {
        let text = NSAttributedString(string: "Installed", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white])
        let size = text.size()
        let pill = NSRect(x: r.minX + 8, y: r.maxY - 28, width: ceil(size.width) + 30, height: 20)
        NSColor.black.withAlphaComponent(0.66).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 10, yRadius: 10).fill()
        StoreStyle.green.setFill()
        NSBezierPath(ovalIn: NSRect(x: pill.minX + 8, y: pill.midY - 3.5, width: 7, height: 7)).fill()
        text.draw(at: NSPoint(x: pill.minX + 20, y: pill.midY - size.height / 2))
    }

    private func drawProgress(_ p: Double, in r: NSRect) {
        NSColor.black.withAlphaComponent(0.66).setFill()
        r.fill()
        let value = max(0, min(100, p))
        let pct = NSAttributedString(string: "\(Int(value.rounded()))%", attributes: [
            .font: StoreStyle.rounded(26, .bold), .foregroundColor: NSColor.white])
        let size = pct.size()
        pct.draw(at: NSPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2 - 8))
        let track = NSRect(x: r.minX + 18, y: r.midY + size.height / 2 - 2, width: r.width - 36, height: 5)
        NSColor.white.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: track, xRadius: 2.5, yRadius: 2.5).fill()
        let w = track.width * CGFloat(value / 100)
        if w > 0 {
            accent.setFill()
            NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: max(w, 5), height: 5),
                         xRadius: 2.5, yRadius: 2.5).fill()
        }
    }
}

/// The title under a cover (two lines at most), a view of its own above the cover, so the cover's
/// shadow never dims it.
private final class StoreTitleView: NSView {
    var title = "" { didSet { needsDisplay = true } }
    /// The title in the softer colour (the game isn't installed).
    var dimmed = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: dimmed ? NSColor.secondaryLabelColor : NSColor.labelColor,
            .paragraphStyle: para,
        ]
        let box = NSRect(x: 5, y: 4, width: max(0, bounds.width - 10), height: 31)
        (title as NSString).draw(with: box, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
    }
}

/// A grid cell's view: the cover, and the title under it. It follows whatever size the grid gives it.
/// The mouse over it pops the cover and raises the cell above the ones beside it.
private final class StoreTileView: NSView {
    static let labelHeight: CGFloat = 38
    let cover = StoreCoverView()
    private let label = StoreTitleView()
    var title: String {
        get { label.title }
        set { label.title = newValue }
    }
    var dimmed: Bool {
        get { label.dimmed }
        set { label.dimmed = newValue }
    }

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true                       // (so a popped cover can be raised above its neighbours: zPosition)
        clipsToBounds = false                   // the popped cover reaches past the cell
        addSubview(cover)
        addSubview(label)
        arrange()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        arrange()
    }

    /// The cover's view is the cell's cover area plus a margin all round (room for the pop and its shadow).
    private func arrange() {
        let m = StoreCoverView.margin
        cover.frame = NSRect(x: -m, y: -m, width: bounds.width + 2 * m,
                             height: max(0, bounds.height - StoreTileView.labelHeight) + 2 * m)
        label.frame = NSRect(x: 0, y: max(0, bounds.height - StoreTileView.labelHeight),
                             width: bounds.width, height: StoreTileView.labelHeight)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas where a.owner === self { removeTrackingArea(a) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    func setHovered(_ on: Bool, animated: Bool = true) {
        layer?.zPosition = on ? 10 : 0
        cover.setHovered(on, animated: animated)
    }
}

/// One cell of the grid.
final class StoreTile: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("StoreTile")
    private let tile = StoreTileView(frame: NSRect(origin: .zero, size: StoreTile.size(forWidth: 158)))
    private var serial = 0

    /// A cell `w` wide: GOG's covers are 342 by 482 (Epic's a little wider, cropped to fit), drawn with room for the ring, the title under them.
    static func size(forWidth w: CGFloat) -> NSSize {
        return NSSize(width: w, height: ((w - 8) * 1.41).rounded() + 8 + StoreTileView.labelHeight)
    }

    override func loadView() { view = tile }

    override var isSelected: Bool {
        didSet { tile.cover.selected = isSelected }
    }

    /// A cell that was scrolled away comes back resting, whatever the mouse was doing.
    override func prepareForReuse() {
        super.prepareForReuse()
        tile.setHovered(false, animated: false)
    }

    /// For the picture test: the cell as if the mouse were over it.
    func popForTest() {
        tile.superview?.addSubview(tile, positioned: .above, relativeTo: nil)
        tile.setHovered(true, animated: false)
    }

    func configure(_ g: StoreGame, progress: Double?, store: StoreInfo) {
        serial += 1
        let mine = serial
        tile.cover.accent = store.accent
        tile.title = g.title
        tile.dimmed = !g.installed
        tile.cover.title = g.title
        tile.cover.installed = g.installed
        tile.cover.progress = progress
        tile.cover.image = nil
        tile.cover.selected = isSelected
        store.art.cover(for: g) { [weak self] img in
            guard let self = self, self.serial == mine else { return }
            self.tile.cover.image = img
        }
    }

    func setProgress(_ p: Double?) { tile.cover.progress = p }
}

// MARK: - small controls

/// The main button: a filled pill in the store's colour.
final class StorePillButton: NSButton {
    var fill = NSColor.systemBlue { didSet { needsDisplay = true } }

    convenience init(_ title: String) {
        self.init(frame: .zero)
        self.title = title
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        setButtonType(.momentaryLight)
        font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        focusRingType = .default
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var title: String {
        didSet { invalidateIntrinsicContentSize(); needsDisplay = true }
    }

    override var isEnabled: Bool {
        didSet { needsDisplay = true }
    }

    override var intrinsicContentSize: NSSize {
        let w = (title as NSString).size(withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 13)]).width
        return NSSize(width: ceil(w) + 40, height: 30)
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
        if isEnabled {
            (isHighlighted ? fill.blended(withFraction: 0.25, of: .black) ?? fill : fill).setFill()
        } else {
            NSColor.white.withAlphaComponent(0.10).setFill()
        }
        shape.fill()
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let s = NSAttributedString(string: title, attributes: [
            .font: font ?? NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(isEnabled ? 1 : 0.4),
            .paragraphStyle: para,
        ])
        let h = s.size().height
        s.draw(in: NSRect(x: 0, y: (bounds.height - h) / 2, width: bounds.width, height: h))
    }
}

/// A thin download line along the top of the install bar.
final class StoreLineBar: NSView {
    var value: Double? { didSet { needsDisplay = true } }       // 0...100; nil: nothing drawn
    var accent = NSColor.systemBlue { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let v = value else { return }
        NSColor.white.withAlphaComponent(0.08).setFill()
        bounds.fill()
        accent.setFill()
        NSRect(x: 0, y: 0, width: bounds.width * CGFloat(max(0, min(100, v)) / 100), height: bounds.height).fill()
    }
}

/// The install bar's backdrop, a little darker than the window.
private final class StoreTray: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.16).setFill()
        bounds.fill()
    }
}

private final class StoreStepBadge: NSView {
    let number: Int
    let accent: NSColor

    init(_ n: Int, accent: NSColor) {
        number = n
        self.accent = accent
        super.init(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 24).isActive = true
        heightAnchor.constraint(equalToConstant: 24).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        accent.withAlphaComponent(0.26).setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()
        let s = NSAttributedString(string: "\(number)", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.labelColor])
        let size = s.size()
        s.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }
}

// MARK: - the window's content

/// Everything inside a store's window. One of four screens shows at a time: loading, a
/// message (trouble), sign-in, or the library.
final class StoreContentView: NSView, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout {
    enum Mode { case loading, message, signIn, library }

    let store: StoreInfo

    var onOpenLogin: (() -> Void)?
    var onSignIn: ((String) -> Void)?
    var onSignOut: (() -> Void)?
    var onRefresh: (() -> Void)?
    var onRetry: (() -> Void)?
    var onInstall: ((StoreGame, StoreFolder?) -> Void)?
    var onRemove: ((StoreGame) -> Void)?

    private(set) var mode = Mode.loading
    /// A command is running (not a download): nothing that would start another is offered.
    var locked = false { didSet { refreshTray(); updateControls() } }

    private var games: [StoreGame] = []
    private var shown: [StoreGame] = []
    private var folders: [StoreFolder] = []
    private var progress: [String: Double] = [:]
    private var busyID: String?
    private var busyText = ""
    private var note: (id: String, text: String)?

    // loading
    private let loadingView = NSView()
    private let spinner = NSProgressIndicator()
    private let loadingLabel = NSTextField(labelWithString: "")

    // message
    private let messageView = NSView()
    private let messageIcon = NSImageView()
    private let messageTitle = NSTextField(labelWithString: "")
    private let messageDetail = NSTextField(wrappingLabelWithString: "")
    private let messageButton = StorePillButton("Try again")

    // sign-in
    private let signInView = NSView()
    private let codeField = NSTextField()
    private let openLoginButton = NSButton(title: "Open Sign-In", target: nil, action: nil)
    private let signInButton = StorePillButton("Sign In")

    // library
    private let library = NSView()
    private let search = NSSearchField()
    private let filter = NSSegmentedControl(labels: ["All", "Installed"], trackingMode: .selectOne, target: nil, action: nil)
    private let sortPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var sort = StoreSort.nameAZ
    private let countLabel = NSTextField(labelWithString: "")
    private let refreshButton = NSButton(title: "", target: nil, action: nil)
    private let account = NSPopUpButton(frame: .zero, pullsDown: true)
    private let scroll = NSScrollView()
    private let collection = NSCollectionView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let trayBar = StoreLineBar()
    private let trayTitle = NSTextField(labelWithString: "")
    private let traySub = NSTextField(labelWithString: "")
    private let folderLabel = NSTextField(labelWithString: "Install to")
    private let folderPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let removeButton = NSButton(title: "Remove…", target: nil, action: nil)
    private let primary = StorePillButton("Install")

    init(frame: NSRect, store: StoreInfo) {
        self.store = store
        super.init(frame: frame)
        for b in [messageButton, signInButton, primary] { b.fill = store.fill }
        trayBar.accent = store.accent
        sort = StoreSort(rawValue: UserDefaults.standard.integer(forKey: StoreContentView.sortKey(store))) ?? .nameAZ
        buildLoading()
        buildMessage()
        buildSignIn()
        buildLibrary()
        showLoading("Asking \(store.name)…")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Where the chosen order is kept (one for each store).
    private static func sortKey(_ store: StoreInfo) -> String { "StoreSort.\(store.id)" }

    // MARK: building

    private func fill(_ host: NSView, with v: NSView) {
        v.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: host.topAnchor),
            v.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            v.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        ])
    }

    /// `stack` in the middle of `host`, `width` wide, a little above the centre.
    private func center(_ stack: NSView, in host: NSView, width: CGFloat) {
        stack.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: host.centerYAnchor, constant: -14),
            stack.widthAnchor.constraint(equalToConstant: width),
        ])
    }

    private func wrapping(_ s: String, size: CGFloat, color: NSColor = .secondaryLabelColor, width: CGFloat,
                          center: Bool = false) -> NSTextField {
        let t = NSTextField(wrappingLabelWithString: s)
        t.font = NSFont.systemFont(ofSize: size)
        t.textColor = color
        if center { t.alignment = .center }
        t.translatesAutoresizingMaskIntoConstraints = false
        t.widthAnchor.constraint(equalToConstant: width).isActive = true
        return t
    }

    private func buildLoading() {
        fill(self, with: loadingView)
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isIndeterminate = true
        loadingLabel.font = NSFont.systemFont(ofSize: 13)
        loadingLabel.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [spinner, loadingLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        center(stack, in: loadingView, width: 320)
    }

    private func buildMessage() {
        fill(self, with: messageView)
        messageIcon.contentTintColor = .tertiaryLabelColor
        messageIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 34, weight: .light)
        messageTitle.font = NSFont.systemFont(ofSize: 17, weight: .semibold)
        messageTitle.alignment = .center
        messageDetail.font = NSFont.systemFont(ofSize: 13)
        messageDetail.textColor = .secondaryLabelColor
        messageDetail.alignment = .center
        messageDetail.translatesAutoresizingMaskIntoConstraints = false
        messageDetail.widthAnchor.constraint(equalToConstant: 400).isActive = true
        messageButton.target = self
        messageButton.action = #selector(retryPressed(_:))
        let stack = NSStackView(views: [messageIcon, messageTitle, messageDetail, messageButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.setCustomSpacing(16, after: messageDetail)
        center(stack, in: messageView, width: 420)
    }

    private func buildSignIn() {
        fill(self, with: signInView)
        let title = NSTextField(labelWithString: "Sign in to \(store.name)")
        title.font = NSFont.systemFont(ofSize: 24, weight: .semibold)
        let intro = wrapping("Install the games you own. Portalistic downloads them inside the bottle and adds them to Steam, where they run through Proton like your Steam games.",
                             size: 13, width: 460)

        openLoginButton.title = store.loginButton
        openLoginButton.target = self
        openLoginButton.action = #selector(openLoginPressed(_:))
        openLoginButton.bezelStyle = .rounded
        codeField.placeholderString = store.codePlaceholder
        codeField.target = self
        codeField.action = #selector(signInPressed(_:))
        codeField.translatesAutoresizingMaskIntoConstraints = false
        codeField.widthAnchor.constraint(equalToConstant: 426).isActive = true
        signInButton.target = self
        signInButton.action = #selector(signInPressed(_:))

        let step1 = step(1, store.steps[0], extra: [openLoginButton])
        let step2 = step(2, store.steps[1], extra: [])
        let step3 = step(3, store.steps[2], extra: [codeField, signInButton])
        let steps = NSStackView(views: [step1, step2, step3])
        steps.orientation = .vertical
        steps.alignment = .leading
        steps.spacing = 18

        let privacy = wrapping(store.privacy, size: 12, color: .tertiaryLabelColor, width: 460)
        let stack = NSStackView(views: [title, intro, steps, privacy])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.setCustomSpacing(22, after: intro)
        stack.setCustomSpacing(24, after: steps)
        center(stack, in: signInView, width: 460)
    }

    private func step(_ n: Int, _ text: String, extra: [NSView]) -> NSView {
        let label = wrapping(text, size: 13, color: .labelColor, width: 426)
        let column = NSStackView(views: [label] + extra)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 9
        let row = NSStackView(views: [StoreStepBadge(n, accent: store.accent), column])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 10
        return row
    }

    private func buildLibrary() {
        fill(self, with: library)

        // the top row: search and filter on the left, the account on the right
        search.placeholderString = "Search your games"
        search.sendsSearchStringImmediately = true
        search.target = self
        search.action = #selector(searchChanged(_:))
        search.translatesAutoresizingMaskIntoConstraints = false
        search.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        let wish = search.widthAnchor.constraint(equalToConstant: 240)     // (gives way when the window is narrow)
        wish.priority = NSLayoutConstraint.Priority(749)
        wish.isActive = true
        filter.target = self
        filter.action = #selector(searchChanged(_:))
        filter.selectedSegment = 0
        for o in StoreSort.allCases {
            sortPopup.addItem(withTitle: o.title)
            sortPopup.lastItem?.tag = o.rawValue
        }
        sortPopup.selectItem(withTag: sort.rawValue)
        sortPopup.target = self
        sortPopup.action = #selector(sortChanged(_:))
        sortPopup.toolTip = "The order of the games. Installed games always come first."
        sortPopup.setAccessibilityLabel("Order of the games")
        countLabel.font = NSFont.systemFont(ofSize: 12)
        countLabel.textColor = .secondaryLabelColor
        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")
        refreshButton.isBordered = false
        refreshButton.contentTintColor = .secondaryLabelColor
        refreshButton.toolTip = "Ask \(store.name) for your games again"
        refreshButton.target = self
        refreshButton.action = #selector(refreshPressed(_:))
        account.bezelStyle = .rounded
        let left = NSStackView(views: [search, filter, sortPopup])
        left.orientation = .horizontal
        left.spacing = 12
        left.alignment = .centerY
        let right = NSStackView(views: [countLabel, refreshButton, account])
        right.orientation = .horizontal
        right.spacing = 10
        right.alignment = .centerY
        let header = NSView()
        for v in [left, right] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(v)
        }
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 24),
            left.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            right.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -24),
            right.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            right.leadingAnchor.constraint(greaterThanOrEqualTo: left.trailingAnchor, constant: 16),
        ])

        // the grid
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = StoreTile.size(forWidth: 158)
        layout.minimumInteritemSpacing = 14
        layout.minimumLineSpacing = 18
        layout.sectionInset = NSEdgeInsets(top: 20, left: 24, bottom: 24, right: 24)
        collection.collectionViewLayout = layout
        collection.dataSource = self
        collection.delegate = self
        collection.isSelectable = true
        collection.allowsMultipleSelection = false
        collection.backgroundColors = [.clear]
        collection.register(StoreTile.self, forItemWithIdentifier: StoreTile.identifier)
        scroll.documentView = collection
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        emptyLabel.font = NSFont.systemFont(ofSize: 14)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center

        // the install bar
        let tray = StoreTray()
        trayTitle.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        trayTitle.lineBreakMode = .byTruncatingTail
        trayTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        traySub.font = NSFont.systemFont(ofSize: 12)
        traySub.textColor = .secondaryLabelColor
        traySub.lineBreakMode = .byTruncatingTail
        traySub.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        folderLabel.font = NSFont.systemFont(ofSize: 12)
        folderLabel.textColor = .secondaryLabelColor
        removeButton.bezelStyle = .rounded
        removeButton.target = self
        removeButton.action = #selector(removePressed(_:))
        primary.target = self
        primary.action = #selector(installPressed(_:))
        let info = NSStackView(views: [trayTitle, traySub])
        info.orientation = .vertical
        info.alignment = .leading
        info.spacing = 3
        let actions = NSStackView(views: [folderLabel, folderPopup, removeButton, primary])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 10
        actions.setCustomSpacing(6, after: folderLabel)
        for v in [info, actions, trayBar] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            tray.addSubview(v)
        }
        NSLayoutConstraint.activate([
            info.leadingAnchor.constraint(equalTo: tray.leadingAnchor, constant: 24),
            info.centerYAnchor.constraint(equalTo: tray.centerYAnchor, constant: 1),
            info.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -16),
            actions.trailingAnchor.constraint(equalTo: tray.trailingAnchor, constant: -24),
            actions.centerYAnchor.constraint(equalTo: tray.centerYAnchor, constant: 1),
            trayBar.topAnchor.constraint(equalTo: tray.topAnchor),
            trayBar.leadingAnchor.constraint(equalTo: tray.leadingAnchor),
            trayBar.trailingAnchor.constraint(equalTo: tray.trailingAnchor),
            trayBar.heightAnchor.constraint(equalToConstant: 3),
        ])

        let top = NSBox()
        top.boxType = .separator
        let bottom = NSBox()
        bottom.boxType = .separator
        for v in [header, top, scroll, bottom, tray, emptyLabel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            library.addSubview(v)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: library.topAnchor),
            header.leadingAnchor.constraint(equalTo: library.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: library.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 56),
            top.topAnchor.constraint(equalTo: header.bottomAnchor),
            top.leadingAnchor.constraint(equalTo: library.leadingAnchor),
            top.trailingAnchor.constraint(equalTo: library.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: top.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: library.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: library.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottom.topAnchor),
            bottom.leadingAnchor.constraint(equalTo: library.leadingAnchor),
            bottom.trailingAnchor.constraint(equalTo: library.trailingAnchor),
            bottom.bottomAnchor.constraint(equalTo: tray.topAnchor),
            tray.leadingAnchor.constraint(equalTo: library.leadingAnchor),
            tray.trailingAnchor.constraint(equalTo: library.trailingAnchor),
            tray.bottomAnchor.constraint(equalTo: library.bottomAnchor),
            tray.heightAnchor.constraint(equalToConstant: 80),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
    }

    // MARK: screens

    private func updateVisibility() {
        library.isHidden = mode != .library
        signInView.isHidden = mode != .signIn
        loadingView.isHidden = mode != .loading
        messageView.isHidden = mode != .message
        if mode == .loading { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    func showLoading(_ text: String) {
        mode = .loading
        loadingLabel.stringValue = text
        updateVisibility()
    }

    /// Trouble, or an empty library: what's wrong and, with `retry`, a button that asks again.
    func showMessage(_ title: String, _ detail: String, retry: String? = "Try again", symbol: String = "exclamationmark.triangle") {
        mode = .message
        messageIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        messageTitle.stringValue = title
        messageDetail.stringValue = detail
        messageButton.title = retry ?? ""
        messageButton.isHidden = retry == nil
        updateVisibility()
    }

    func showSignIn() {
        mode = .signIn
        updateVisibility()
        updateControls()
    }

    func clearCode() { codeField.stringValue = "" }

    func showLibrary(user: String, games all: [StoreGame], folders list: [StoreFolder]) {
        mode = .library
        games = all
        folders = list
        account.removeAllItems()
        account.addItem(withTitle: user.isEmpty ? "Signed in" : user)
        account.addItem(withTitle: "Sign Out…")
        if let item = account.menu?.item(at: 1) {
            item.target = self
            item.action = #selector(signOutPicked(_:))
        }
        folderPopup.removeAllItems()
        for f in folders { folderPopup.addItem(withTitle: "\(f.label), \(StoreStyle.bytes(f.free)) free") }
        if let i = folders.firstIndex(where: { $0.isDefault }) { folderPopup.selectItem(at: i) }
        updateVisibility()
        applyFilter()
        updateControls()
    }

    /// New game states (after an install or a removal), the grid and the choices left as they are.
    func updateGames(_ all: [StoreGame]) {
        games = all
        applyFilter()
        // an installed game moves up to the installed ones: keep the chosen cover in view
        if let ip = collection.selectionIndexPaths.first {
            collection.scrollToItems(at: [ip], scrollPosition: .centeredVertically)
        }
    }

    // MARK: the running download

    /// A download (or removal) is running on game `id`: its cover shows `pct`, the bar says `text`.
    /// `id` nil: it ended.
    func setBusy(_ id: String?, progress pct: Double?, text: String) {
        let old = busyID
        busyID = id
        busyText = text
        if let o = old, o != id {
            progress[o] = nil
            touch(o)
        }
        if let i = id {
            progress[i] = pct
            touch(i)
        }
        refreshTray()
    }

    /// Pops a game's cover as the mouse over it would (the picture test uses it).
    func pop(_ id: String) {
        guard let row = shown.firstIndex(where: { $0.id == id }),
              let item = collection.item(at: IndexPath(item: row, section: 0)) as? StoreTile else { return }
        item.popForTest()
    }

    /// Chooses a game's cover, as a click would (the picture test uses it).
    func select(_ id: String) {
        guard let row = shown.firstIndex(where: { $0.id == id }) else { return }
        collection.selectionIndexPaths = [IndexPath(item: row, section: 0)]
        selectionChanged()
    }

    /// New words for the bar while a download or removal runs.
    func setBusyText(_ text: String) {
        guard busyID != nil else { return }
        busyText = text
        refreshTray()
    }

    /// New progress (and words) for the running download.
    func setBusyProgress(_ pct: Double, text: String) {
        guard let i = busyID else { return }
        progress[i] = pct
        busyText = text
        touch(i)
        refreshTray()
    }

    /// A line to show under the game's name in the bar (until another game is chosen).
    func setNote(_ id: String, _ text: String) {
        note = (id, text)
        refreshTray()
    }

    private func touch(_ id: String) {
        guard let row = shown.firstIndex(where: { $0.id == id }),
              let item = collection.item(at: IndexPath(item: row, section: 0)) as? StoreTile else { return }
        item.setProgress(progress[id])
    }

    // MARK: the grid

    private var selectedGame: StoreGame? {
        guard let ip = collection.selectionIndexPaths.first, ip.item < shown.count else { return nil }
        return shown[ip.item]
    }

    private func applyFilter() {
        let keep = selectedGame?.id
        let q = search.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        let onlyInstalled = filter.selectedSegment == 1
        shown = sort.arranged(games.filter { (!onlyInstalled || $0.installed) && (q.isEmpty || $0.title.lowercased().contains(q)) })
        collection.reloadData()
        if let k = keep, let row = shown.firstIndex(where: { $0.id == k }) {
            collection.selectionIndexPaths = [IndexPath(item: row, section: 0)]
        }
        let have = games.filter { $0.installed }.count
        countLabel.stringValue = games.isEmpty ? "" : "\(games.count) games, \(have) installed"
        if games.isEmpty {
            emptyLabel.stringValue = store.noGames
        } else if shown.isEmpty {
            emptyLabel.stringValue = onlyInstalled && q.isEmpty ? "Nothing installed yet." : "No games match."
        } else {
            emptyLabel.stringValue = ""
        }
        refreshTray()
    }

    func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { shown.count }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: StoreTile.identifier, for: indexPath)
        if let tile = item as? StoreTile, indexPath.item < shown.count {
            let g = shown[indexPath.item]
            tile.configure(g, progress: progress[g.id], store: store)
        }
        return item
    }

    /// As many columns as fit with cells at least 148 wide, the cells then widened to fill the row.
    func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> NSSize {
        let inset: CGFloat = 24
        let gap: CGFloat = 14
        let least: CGFloat = 148
        let room = max(scroll.contentSize.width - 2 * inset - 2, least)       // (2 spare, or an exact fit can round out)
        let columns = max(1, Int(((room + gap) / (least + gap)).rounded(.down)))
        let width = floor((room - CGFloat(columns - 1) * gap) / CGFloat(columns))
        return StoreTile.size(forWidth: width)
    }

    private var gridWidth: CGFloat = 0

    override func layout() {
        super.layout()
        let w = scroll.contentSize.width
        if abs(w - gridWidth) > 0.5 {                 // the window was resized: the cells follow
            gridWidth = w
            collection.collectionViewLayout?.invalidateLayout()
        }
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        selectionChanged()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        selectionChanged()
    }

    private func selectionChanged() {
        if let n = note, n.id != selectedGame?.id { note = nil }
        refreshTray()
    }

    // MARK: the install bar

    private func updateControls() {
        refreshButton.isEnabled = !locked && busyID == nil
        account.isEnabled = !locked && busyID == nil
        signInButton.isEnabled = !locked
        openLoginButton.isEnabled = !locked
    }

    private func refreshTray() {
        updateControls()
        let busy = busyID != nil
        let game = busy ? games.first(where: { $0.id == busyID }) : selectedGame
        trayBar.value = busy ? busyID.flatMap { progress[$0] } : nil
        guard let g = game else {
            trayTitle.stringValue = games.isEmpty ? "" : "Choose a game"
            traySub.stringValue = games.isEmpty ? "" : "Pick a cover to install it, or to remove it again."
            folderLabel.isHidden = true
            folderPopup.isHidden = true
            removeButton.isHidden = true
            primary.isHidden = true
            return
        }
        trayTitle.stringValue = g.title
        if busy {
            traySub.stringValue = busyText
            folderLabel.isHidden = true
            folderPopup.isHidden = true
            removeButton.isHidden = true
            primary.isHidden = true
            return
        }
        if let n = note, n.id == g.id {
            traySub.stringValue = n.text
        } else if g.installed {
            let base = g.size > 0 ? "Installed, \(StoreStyle.bytes(g.size))" : "Installed"
            traySub.stringValue = g.update ? base + ". A newer version is available." : base
        } else {
            traySub.stringValue = "Not installed"
        }
        if g.year > 0, !(note?.id == g.id) {
            let s = traySub.stringValue
            traySub.stringValue = s + (s.hasSuffix(".") ? " " : ". ") + "Released \(g.year)."
        }
        folderLabel.isHidden = g.installed || folders.isEmpty
        folderPopup.isHidden = g.installed || folders.isEmpty
        removeButton.isHidden = !g.installed
        primary.isHidden = false
        primary.title = g.installed ? "Update" : "Install"
        removeButton.isEnabled = !locked
        primary.isEnabled = !locked
    }

    // MARK: actions

    @objc private func searchChanged(_ sender: Any?) { applyFilter() }

    @objc private func sortChanged(_ sender: Any?) {
        guard let o = StoreSort(rawValue: sortPopup.selectedItem?.tag ?? 0) else { return }
        setSort(o)
    }

    /// Chooses the order of the games (the picture test uses it too) and keeps the choice for this store.
    func setSort(_ o: StoreSort) {
        sort = o
        sortPopup.selectItem(withTag: o.rawValue)
        UserDefaults.standard.set(o.rawValue, forKey: StoreContentView.sortKey(store))
        applyFilter()
        collection.scroll(.zero)
    }
    @objc private func refreshPressed(_ sender: Any?) { onRefresh?() }
    @objc private func signOutPicked(_ sender: Any?) { onSignOut?() }
    @objc private func retryPressed(_ sender: Any?) { onRetry?() }
    @objc private func openLoginPressed(_ sender: Any?) { onOpenLogin?() }

    @objc private func signInPressed(_ sender: Any?) {
        onSignIn?(codeField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @objc private func installPressed(_ sender: Any?) {
        guard let g = selectedGame else { return }
        let i = folderPopup.indexOfSelectedItem
        onInstall?(g, !g.installed && i >= 0 && i < folders.count ? folders[i] : nil)
    }

    @objc private func removePressed(_ sender: Any?) {
        guard let g = selectedGame, g.installed else { return }
        onRemove?(g)
    }
}
