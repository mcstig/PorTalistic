//
//  GameArtwork.swift
//  PorTalistic
//
//  Created by Claude Opus 5 on 14/9/2026.
//

// Copyright © 2023-2025 vapidinfinity
// Copyright © 2026 Michael Stoian

import SwiftUI
import AppKit
import Shimmer

/**
 A game's cover art, and something worth looking at when there isn't any.

 Most of a real library has no cover art: Epic publishes portrait covers for its own
 storefront titles and nothing for the rest, GOG's are inconsistent, and a game imported
 from a folder has never had one. The previous card drew `.quinary` — flat grey — behind a
 shimmer for those, so a 129-game library rendered as 129 identical grey rectangles, and a
 card whose URL failed outright drew a full `ContentUnavailableView` with a title, a
 description and a button inside 200 points of width.

 Here a missing image is a *designed* state: a colour derived from the title, so every game
 looks like itself and stays that colour between launches, marked with the app's portal
 motif and the game's initials. Cover art, when it exists, simply covers it.
 */
struct GameArtwork: View {
    let game: Game?
    let url: URL?

    /// Which way round the art is, which decides what a missing image should be shaped like.
    var orientation: Orientation = .vertical

    var cornerRadius: CGFloat = Theme.Radius.tile

    /// Greys, a little darker, for a game that isn't installed — so the eye goes to what can be
    /// played. Callers turn it off under the pointer, which is when the colour comes back.
    var isMuted: Bool = false

    /// Reports whether real artwork is on screen, for callers that need to know.
    var isArtworkPresent: Binding<Bool>?

    enum Orientation { case vertical, horizontal }

    /// Seeded from the cache so a card that has been seen before draws its art on its first
    /// frame, rather than showing the placeholder for one frame on every scroll.
    @State private var image: NSImage?

    /// The grey copy — see ``ArtworkCache/mutedImage(for:)`` — and the URL it was made from.
    ///
    /// Kept for as long as the view is, so the pointer arriving and leaving swaps between two
    /// pictures that already exist. The URL is kept with it because a cover can change while
    /// its card is on screen — a custom thumbnail picked in the game's settings — and without
    /// it the old cover came back, in grey, the moment the pointer left.
    @State private var mutedImage: NSImage?
    @State private var mutedImageURL: URL?

    /// The grey copy, if it is of the picture this view is showing now.
    private var currentMutedImage: NSImage? { mutedImageURL == url ? mutedImage : nil }

    /// Bumped to retry. A failure is kept — a URL that 404s will 404 again — so retrying has
    /// to be asked for, by this changing.
    @State private var attempt: Int = 0
    @State private var isRetrying: Bool = false

    /// Set when the retries are spent, so the loading shimmer stops.
    ///
    /// `.shimmering(animation: .repeatForever)` is a layer animating at the display's
    /// refresh rate for as long as it is on screen. Most of a real library has no cover art,
    /// so a grid of those was dozens of animations running forever behind a scroll that had
    /// to fight them for frames.
    @State private var hasGivenUp: Bool = false

    init(game: Game? = nil,
         url: URL?,
         orientation: Orientation = .vertical,
         cornerRadius: CGFloat = Theme.Radius.tile,
         isMuted: Bool = false,
         isArtworkPresent: Binding<Bool>? = nil) {
        self.game = game
        self.url = url
        self.orientation = orientation
        self.cornerRadius = cornerRadius
        self.isMuted = isMuted
        self.isArtworkPresent = isArtworkPresent
        self._image = .init(initialValue: url.flatMap { ArtworkCache.shared.cachedImage(for: $0) })
        let cachedMuted = isMuted ? url.flatMap { ArtworkCache.shared.cachedMutedImage(for: $0) } : nil
        self._mutedImage = .init(initialValue: cachedMuted)
        self._mutedImageURL = .init(initialValue: cachedMuted == nil ? nil : url)
    }

    private var shape: RoundedRectangle { .init(cornerRadius: cornerRadius, style: .continuous) }

    var body: some View {
#if DEBUG
        RenderCounter.record("GameArtwork")
#endif
        // `Color.clear` takes whatever size it is offered, and an overlay never reports its
        // own size upward — which is the whole point of the arrangement.
        //
        // With the artwork in a `ZStack` instead, a `resizable` image with `.fill` overflows
        // the proposal and the stack grows to the *image's* size. `clipShape` clips the
        // drawing but not the layout, so cards ended up as big as whatever cover art they
        // happened to hold: GOG publishes larger covers than Epic, so a row of GOG games was
        // visibly taller and wider than a row of Epic ones in the same grid, and the outer
        // `aspectRatio` never got a look in.
        return Color.clear
            .overlay {
                ZStack {
                    // The placeholder is drawn *instead of* the artwork, not underneath it.
                    // Underneath, every card with a cover was still rendering a gradient, a
                    // ring watermark in a soft-light blend and two lines of text behind an
                    // opaque image — paid for on every frame, visible on none.
                    //
                    // No cross-fade either. Art fading in over the placeholder means both
                    // are half-transparent for the length of the animation, so the game's
                    // initials ghost through its own cover art.
                    if let image {
                        // One picture at a time — grey while muted, colour otherwise. The two only
                        // overlap for the moment the pointer arrives or leaves.
                        if isMuted {
                            if let muted = currentMutedImage {
                                Image(nsImage: muted)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                            } else {
                                // The grey copy is still being made, which takes a frame or two.
                                // The same look from filters until then, rather than a flash of
                                // colour — and only until then, because a filter is drawn again
                                // on every frame of a scroll.
                                Image(nsImage: image)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .saturation(0)
                                    .colorMultiply(Color(white: 0.75))
                            }
                        } else {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        }
                    } else {
                        ArtworkPlaceholder(game: game, orientation: orientation, isMuted: isMuted)

                        if url != nil, !hasGivenUp {
                            Rectangle()
                                .fill(.white.opacity(0.06))
                                .shimmering(animation: .easeInOut(duration: 1.1).repeatForever(autoreverses: false),
                                            bandSize: 0.8)
                        }
                    }
                }
            }
            .clipShape(shape)
            // A border belongs on a tile, not on a hero: at `cornerRadius: 0` this drew a
            // separator-coloured line down both sides of a full-bleed image.
            .conditionalTransform(if: cornerRadius > 0) { $0.hairlineBorder(shape) }
            .task(id: taskIdentity) { await load() }
            .task(id: mutedTaskIdentity) { await loadMutedIfNeeded() }
    }

    private var taskIdentity: String { "\(url?.absoluteString ?? "")#\(attempt)" }

    /// Changes whenever a grey copy might newly be needed: muting turned on, the picture
    /// arriving, or a different picture. The arrival matters: without it, a card whose pointer
    /// left while its cover was still downloading waited for a change that had already happened,
    /// and stayed on the filtered stand-in for good.
    private var mutedTaskIdentity: String { "\(isMuted)#\(image != nil)#\(url?.absoluteString ?? "")" }

    private func load() async {
        guard let url else {
            image = nil
            isArtworkPresent?.wrappedValue = false
            return
        }

        if let loaded = await ArtworkCache.shared.image(for: url) {
            // The grey copy before the picture, when it is wanted, so a game that isn't
            // installed never shows its cover in colour for a moment on the way to grey.
            if isMuted, mutedImageURL != url, let muted = await ArtworkCache.shared.mutedImage(for: url) {
                mutedImage = muted
                mutedImageURL = url
            }

            image = loaded
            isArtworkPresent?.wrappedValue = true
        } else {
            isArtworkPresent?.wrappedValue = false
            scheduleRetry()
        }
    }

    /// The grey copy, when muting is asked for after the picture has already arrived — a game
    /// uninstalled while its card is on screen. `load()` fetches it up front otherwise.
    ///
    /// Its own task rather than part of `load()`'s identity: this runs every time the pointer
    /// arrives or leaves, and `load()` goes to the network for a cover it hasn't got.
    private func loadMutedIfNeeded() async {
        guard isMuted, currentMutedImage == nil, image != nil, let url,
              let muted = await ArtworkCache.shared.mutedImage(for: url) else { return }

        mutedImage = muted
        mutedImageURL = url
    }

    /// Retries a failure a couple of times, spaced out, and then stops.
    ///
    /// Bounded rather than indefinite: a grid of cards quietly retrying dead URLs in a loop
    /// costs the user battery to achieve nothing.
    private func scheduleRetry() {
        guard attempt < 2, !isRetrying else {
            hasGivenUp = true
            return
        }

        isRetrying = true

        Task {
            try? await Task.sleep(for: .seconds(2 << attempt))
            isRetrying = false
            attempt += 1
        }
    }
}

// MARK: - Placeholder

struct ArtworkPlaceholder: View {
    let game: Game?
    var orientation: GameArtwork.Orientation = .vertical

    /// Greys, the same as ``GameArtwork/isMuted``: a game without cover art isn't installed any
    /// less for it.
    var isMuted: Bool = false

    private var seed: UInt64 { Self.stableHash(game?.title ?? "PorTalistic") }

    /// Hue from the title, so a game keeps its colour forever.
    ///
    /// Swift's own `Hasher` is seeded per process, so `title.hashValue` would give a game a
    /// different colour on every launch — which is exactly the kind of thing that makes an
    /// interface feel unreliable without anyone being able to say why.
    private var hue: Double { Double(seed % 3600) / 3600.0 }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(hue: hue, saturation: isMuted ? 0 : 0.44, brightness: isMuted ? 0.32 : 0.44),
                    Color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1),
                          saturation: isMuted ? 0 : 0.62,
                          brightness: isMuted ? 0.15 : 0.20)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            PortalRings()
                .opacity(0.10)

            if let applicationIcon {
                // A native macOS game has an icon of its own, which beats its initials.
                Image(nsImage: applicationIcon)
                    .resizable()
                    .scaledToFit()
                    .padding(orientation == .vertical ? Theme.Spacing.xxlarge : Theme.Spacing.large)
            } else {
                VStack(spacing: Theme.Spacing.small) {
                    Text(initials)
                        .font(.system(size: orientation == .vertical ? 44 : 34, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.82))

                    if let storefront = game?.storefront {
                        Image(systemName: storefront.symbolName)
                            .imageScale(.medium)
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
                .minimumScaleFactor(0.4)
                .padding(Theme.Spacing.small)
            }
        }
        // One picture rather than a gradient, three rings and a line of text, each moved and
        // clipped to the card's corners separately on every frame of a scroll. Most of a real
        // library has no cover art, so most cards are this. It never changes once drawn.
        .drawingGroup()
    }

    /// The bundle's own icon, for a macOS game installed as an application.
    private var applicationIcon: NSImage? {
        guard let game, game.isFallbackImageAvailable,
              case .installed(let location, _) = game.installationState else { return nil }

        // Not for a game on an external drive. Asking for a bundle's icon opens files inside
        // it, and doing that to a removable volume is what makes macOS ask for the drive —
        // here it would happen while a card was being drawn, which is the worst possible
        // moment for a modal prompt. Those games get their initials instead.
        guard !location.isOnAnExternalVolume else { return nil }

        return Self.icon(forFileAt: location.path(percentEncoded: false))
    }

    /// Icons, kept. `NSWorkspace.icon(forFile:)` reaches the filesystem, and this is read
    /// while a card is drawn — so a shelf of native games was hitting the disk on every
    /// frame of a scroll for a picture that had not changed.
    private nonisolated(unsafe) static var memoizedIcons: [String: NSImage] = .init()

    private static func icon(forFileAt path: String) -> NSImage {
        if let cached = memoizedIcons[path] { return cached }

        let icon = NSWorkspace.shared.icon(forFile: path)
        memoizedIcons[path] = icon
        return icon
    }

    /// Up to two initials from the words that carry the name.
    private var initials: String {
        let words = (game?.title ?? "")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .filter { !Self.ignoredWords.contains($0.lowercased()) }

        let letters = words.prefix(2).compactMap(\.first).map { String($0).uppercased() }
        return letters.isEmpty ? "?" : letters.joined()
    }

    private static let ignoredWords: Set<String> = ["a", "an", "the", "of", "and", "in", "to", "for", "at", "on"]

    /// FNV-1a. Small, stable across processes, and good enough to scatter hues.
    private static func stableHash(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}

/// The app's mark, as a watermark: three rings around an off-centre focus.
private struct PortalRings: View {
    var body: some View {
        GeometryReader { geometry in
            let side = max(geometry.size.width, geometry.size.height)

            ZStack {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .strokeBorder(.white, lineWidth: side * 0.035)
                        .frame(width: side * (0.42 + Double(index) * 0.26))
                        .opacity(1 - Double(index) * 0.28)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .offset(x: geometry.size.width * 0.22, y: geometry.size.height * 0.28)
        }
    }
}

// MARK: - Storefront presentation

extension Game.Storefront {
    /// One symbol per storefront, defined once.
    ///
    /// These used to be written out at each call site, so the sidebar, the filter menu and
    /// the badges could and did disagree about what GOG looks like.
    var symbolName: String {
        switch self {
        case .epicGames:    "gamecontroller"
        case .gog:          "building.columns"
        case .steam:        "cloud"
        case .local:        "internaldrive"
        }
    }

    var tint: Color {
        switch self {
        case .epicGames:    .init(red: 0.38, green: 0.42, blue: 0.58)
        case .gog:          .init(red: 0.66, green: 0.35, blue: 0.85)
        case .steam:        .init(red: 0.28, green: 0.52, blue: 0.78)
        case .local:        .init(red: 0.40, green: 0.62, blue: 0.52)
        }
    }

    /// The storefront's own web store, for the ones that have one worth browsing in-app.
    ///
    /// `nil` means no store page: a local game has no store at all, and Steam's is behind
    /// `Steam.isEnabled` along with the rest of it.
    var storeURL: URL? {
        switch self {
        case .epicGames:    .init(string: "https://store.epicgames.com/")
        case .gog:          .init(string: "https://www.gog.com/")
        case .steam:        .init(string: "https://store.steampowered.com/")
        case .local:        nil
        }
    }

    /// What the store page is called in the sidebar and the window title.
    ///
    /// Its own name rather than `"\(description) Store"`, because "Epic Games Store" is the
    /// product's real name and "GOG Store" is not "GOG.com" — and because one sidebar row per
    /// store needs each to be recognisable at a glance.
    var storeName: String? {
        switch self {
        case .epicGames:    String(localized: "Epic Store")
        case .gog:          String(localized: "GOG Store")
        case .steam:        String(localized: "Steam Store")
        case .local:        nil
        }
    }

    /// The WebKit cookie jar this storefront's pages share.
    ///
    /// Shared with the sign-in window on purpose: signing in on either page is then visible
    /// to the other. Both are persisted on first read — see the note on
    /// ``GOG/webDataStoreIdentifier`` for what happens when they are not.
    var webDataStoreIdentifier: UUID? {
        switch self {
        case .epicGames:    Legendary.webDataStoreIdentifier
        case .gog:          GOG.webDataStoreIdentifier
        case .steam, .local: nil
        }
    }

    /// Storefronts with a store page the app will show.
    static var withStores: [Self] {
        available.filter { $0.storeURL != nil && $0.storeName != nil }
    }
}

#Preview("Placeholders") {
    HStack(spacing: Theme.Spacing.large) {
        ForEach(["Blades of Time", "Prey", "A Plague Tale: Innocence", "Horizon Chase Turbo"], id: \.self) { title in
            ArtworkPlaceholder(game: nil, orientation: .vertical)
                .frame(width: 150, height: 200)
                .clipShape(.rect(cornerRadius: Theme.Radius.tile, style: .continuous))
                .overlay(alignment: .bottom) { Text(title).font(.caption).padding(4) }
        }
    }
    .padding(Theme.Spacing.xlarge)
}
