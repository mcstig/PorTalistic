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

    /// Reports whether real artwork is on screen, for callers that need to know.
    var isArtworkPresent: Binding<Bool>?

    enum Orientation { case vertical, horizontal }

    /// Seeded from the cache so a card that has been seen before draws its art on its first
    /// frame, rather than showing the placeholder for one frame on every scroll.
    @State private var image: NSImage?

    /// Bumped to retry. A failure is kept — a URL that 404s will 404 again — so retrying has
    /// to be asked for, by this changing.
    @State private var attempt: Int = 0
    @State private var isRetrying: Bool = false

    init(game: Game? = nil,
         url: URL?,
         orientation: Orientation = .vertical,
         cornerRadius: CGFloat = Theme.Radius.tile,
         isArtworkPresent: Binding<Bool>? = nil) {
        self.game = game
        self.url = url
        self.orientation = orientation
        self.cornerRadius = cornerRadius
        self.isArtworkPresent = isArtworkPresent
        self._image = .init(initialValue: url.flatMap { ArtworkCache.shared.cachedImage(for: $0) })
    }

    private var shape: RoundedRectangle { .init(cornerRadius: cornerRadius, style: .continuous) }

    var body: some View {
        // `Color.clear` takes whatever size it is offered, and an overlay never reports its
        // own size upward — which is the whole point of the arrangement.
        //
        // With the artwork in a `ZStack` instead, a `resizable` image with `.fill` overflows
        // the proposal and the stack grows to the *image's* size. `clipShape` clips the
        // drawing but not the layout, so cards ended up as big as whatever cover art they
        // happened to hold: GOG publishes larger covers than Epic, so a row of GOG games was
        // visibly taller and wider than a row of Epic ones in the same grid, and the outer
        // `aspectRatio` never got a look in.
        Color.clear
            .overlay {
                ZStack {
                    ArtworkPlaceholder(game: game, orientation: orientation)

                    if let image {
                        // No cross-fade. Art fading in *over* the placeholder means both are
                        // half-transparent for the length of the animation, so the game's
                        // initials ghost through its own cover art — worse than either state.
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else if url != nil {
                        Rectangle()
                            .fill(.white.opacity(0.06))
                            .shimmering(animation: .easeInOut(duration: 1.1).repeatForever(autoreverses: false),
                                        bandSize: 0.8)
                    }
                }
            }
            .clipShape(shape)
            // A border belongs on a tile, not on a hero: at `cornerRadius: 0` this drew a
            // separator-coloured line down both sides of a full-bleed image.
            .conditionalTransform(if: cornerRadius > 0) { $0.hairlineBorder(shape) }
            .task(id: taskIdentity) { await load() }
    }

    private var taskIdentity: String { "\(url?.absoluteString ?? "")#\(attempt)" }

    private func load() async {
        guard let url else {
            image = nil
            isArtworkPresent?.wrappedValue = false
            return
        }

        if let loaded = await ArtworkCache.shared.image(for: url) {
            image = loaded
            isArtworkPresent?.wrappedValue = true
        } else {
            isArtworkPresent?.wrappedValue = false
            scheduleRetry()
        }
    }

    /// Retries a failure a couple of times, spaced out, and then stops.
    ///
    /// Bounded rather than indefinite: a grid of cards quietly retrying dead URLs in a loop
    /// costs the user battery to achieve nothing.
    private func scheduleRetry() {
        guard attempt < 2, !isRetrying else { return }
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
                    Color(hue: hue, saturation: 0.44, brightness: 0.44),
                    Color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.62, brightness: 0.20)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            PortalRings()
                .opacity(0.16)

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
    }

    /// The bundle's own icon, for a macOS game installed as an application.
    private var applicationIcon: NSImage? {
        guard let game, game.isFallbackImageAvailable,
              case .installed(let location, _) = game.installationState else { return nil }
        return NSWorkspace.shared.icon(forFile: location.path(percentEncoded: false))
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
            .blendMode(.softLight)
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
        case .epicGames:    .init(red: 0.55, green: 0.55, blue: 0.60)
        case .gog:          .init(red: 0.66, green: 0.35, blue: 0.85)
        case .steam:        .init(red: 0.28, green: 0.52, blue: 0.78)
        case .local:        .init(red: 0.40, green: 0.62, blue: 0.52)
        }
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
