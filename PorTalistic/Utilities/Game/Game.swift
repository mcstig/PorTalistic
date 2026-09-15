//
//  Game.swift
//  Mythic
//
//  Created by vapidinfinity (esi) on 15/11/2025.
//

// Copyright © 2023-2025 vapidinfinity

import Foundation
import OSLog
import AppKit

@Observable class Game: Codable, Identifiable {
    @MainActor static let operationManager: GameOperationManager = .shared

    let id: String
    var title: String
    var installationState: InstallationState

    var storefront: Storefront? {
        assertionFailure("Storefront must always be populated by subclasses, when accessed.")
        return nil
    }

    // swiftlint:disable:next identifier_name
    internal final var _containerURL: URL?
    final var containerURL: URL? {
        get {
            if Wine.containerURLs.first(where: { $0 == _containerURL }) == nil
                || _containerURL == nil {
                _containerURL = Wine.containerURLs.first
            }

            return _containerURL
        }
        set { _containerURL = newValue }
    }

    var isUpdateAvailable: Bool? { nil } // override in subclass

    // swiftlint:disable:next identifier_name
    internal var _verticalImageURL: URL? // underlying storage for custom images
    var verticalImageURL: URL? { _verticalImageURL ?? computedVerticalImageURL }
    internal var computedVerticalImageURL: URL? { nil } // override in subclass — Auto-synthesized (default) image URL

    // swiftlint:disable:next identifier_name
    internal var _horizontalImageURL: URL? // underlying storage for custom images
    var horizontalImageURL: URL? { _horizontalImageURL ?? computedHorizontalImageURL }
    internal var computedHorizontalImageURL: URL? { nil } // override in subclass — Auto-synthesized (default) image URL

    var launchArguments: [String] = []
    final var isFavourited: Bool = false
    final var lastLaunched: Date?

    /// Whether this game's compatibility settings are chosen for it at every launch.
    ///
    /// On by default, and the point of the app: nobody should have to know which Wine build
    /// or which translation layer a game wants. Turning it off does not mean "no settings" —
    /// it means the values in ``settingsOverride`` are used verbatim instead of being worked
    /// out, so switching it off hands over exactly what automatic had arrived at rather than
    /// a blank slate.
    final var isSettingsAutomatic: Bool = true

    /// The settings this game runs with when ``isSettingsAutomatic`` is off.
    ///
    /// Kept even while automatic is on, so turning it off and on again doesn't lose what was
    /// set by hand.
    final var settingsOverride: RuntimeProfile.SettingsOverride = .init()

    // override in subclass
    func getSupportedPlatforms() -> Set<Game.Platform>? { return nil }

    init(id: String,
         title: String,
         installationState: InstallationState,
         containerURL: URL? = nil) {
        self.id = id
        self.title = title
        self.installationState = installationState

        self._containerURL = containerURL ?? Wine.containerURLs.first
    }

    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        self.id = try container.decode(String.self, forKey: .id)
        self.title = try container.decode(String.self, forKey: .title)
        self.installationState = try container.decode(InstallationState.self, forKey: .installationState)
        self._verticalImageURL = try container.decodeIfPresent(URL.self, forKey: ._verticalImageURL)
        self._horizontalImageURL = try container.decodeIfPresent(URL.self, forKey: ._horizontalImageURL)
        self._containerURL = try container.decodeIfPresent(URL.self, forKey: ._containerURL)
        self.launchArguments = try container.decode([String].self, forKey: .launchArguments)
        self.isFavourited = try container.decode(Bool.self, forKey: .isFavourited)
        self.lastLaunched = try container.decodeIfPresent(Date.self, forKey: .lastLaunched)

        // Defaulted rather than required: every game stored before these existed decodes
        // as "let the app decide", which is what it was already doing.
        self.isSettingsAutomatic = try container.decodeIfPresent(Bool.self, forKey: .isSettingsAutomatic) ?? true
        self.settingsOverride = try container.decodeIfPresent(RuntimeProfile.SettingsOverride.self,
                                                              forKey: .settingsOverride) ?? .init()
    }

    final var isFallbackImageAvailable: Bool {
        guard case .installed(_, let platform) = installationState else {
            return false
        }

        switch platform {
        case .macOS:    return true
        case .windows:  return false
        }
    }

    // MARK: Actions
    @MainActor final var isOperating: Bool {
        Game.operationManager.queue.first(where: {
            $0.game == self && $0.isExecuting
        }) != nil
    }

    final func checkIfGameIsRunning() -> Bool {
        guard case .installed(let location, let platform) = installationState else { return false }
        return _checkIfGameIsRunning(location: location, platform: platform)
    }

    /// Launch the underlying game.
    @MainActor final func launch() async throws {
        guard case .installed = installationState else {
            throw CocoaError(.fileNoSuchFile)
        }

        lastLaunched = .now
        try await _launch()
    }

    @MainActor final func update() async throws {
        guard case .installed = installationState else {
            throw CocoaError(.fileNoSuchFile)
        }

        guard isUpdateAvailable == true else { return }

        try await _update()
    }

    /// Move the underlying game to a specified `URL`.
    @MainActor final func move(to newLocation: URL) async throws {
        guard case .installed(let currentLocation, _) = installationState else {
            throw CocoaError(.fileNoSuchFile)
        }

        try await _move(from: currentLocation,
                        to: newLocation)
    }

    /// Verify the file integrity of the game (if it's installed)
    final func verifyInstallation() async throws {
        guard case .installed = installationState else {
            throw CocoaError(.fileNoSuchFile)
        }

        try await _verifyInstallation()
    }

    // MARK: Overrideable Actions

    // override in subclass
    func _checkIfGameIsRunning(location: URL, platform: Platform) -> Bool {
        // swiftlint:disable:previous identifier_name
        Logger.app.warning("""
            _checkIfGameIsRunning() called on \(self).
            This means that the subclass calling this method does not have an override,
            Or that this method was called from the `Game` base class.
            This is not intended behaviour, and thus, a basic fallback will be used.
            """)

        if case .macOS = platform {
            return NSWorkspace.shared.runningApplications.contains(where: { $0.bundleURL == location })
        }

        return false
    }

    // override in subclass
    @MainActor internal func _launch() async throws {
        // swiftlint:disable:previous identifier_name
        fatalError("Subclasses must implement _launch()")
    }

    // override in subclass
    @MainActor internal func _update() async throws {
        // swiftlint:disable:previous identifier_name
        fatalError("Subclasses must implement _update()")
    }

    // override in subclass
    @MainActor internal func _move(from currentLocation: URL, // swiftlint:disable:this identifier_name
                                   to newLocation: URL) async throws {
        fatalError("Subclasses must implement _move(to:)")
    }

    // override in subclass
    internal func _verifyInstallation() async throws {
        // swiftlint:disable:previous identifier_name
        assertionFailure("Subclasses should implement _verifyInstallation()")
    }
}

extension Game: Equatable {
    public static func == (lhs: Game, rhs: Game) -> Bool {
        return lhs.id == rhs.id
    }
}

extension Game: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// `Game` is a reference type that Mythic passes freely between the main actor (SwiftUI
// views, `GameDataStore`) and the nonisolated storefront managers that shell out to
// Legendary/Wine. Swift 6's strict concurrency checking flags every one of those
// hand-offs ("Sending 'game' risks causing data races") because the class isn't
// `Sendable`.
//
// Stating that assumption explicitly here keeps the existing threading behaviour exactly
// as it is. The honest alternative — pinning `Game` and the whole Epic/Legendary manager
// chain to `@MainActor` — would move long-running install/launch work onto the main
// actor, which is a much larger and riskier change than the one this unblocks.
// FIXME: revisit once the storefront managers have a coherent isolation story; the
// mutable state on `Game` should really be main-actor-isolated rather than unchecked.
extension Game: @unchecked Sendable {}

extension Game: CustomStringConvertible {
    var description: String { "\"\(title)\"" }
    var debugDescription: String { "\(description) (\(installationState), \(id))" }
}

// MARK: - Codable Polymorphism Support
extension Game {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case id,
             title,
             installationState
        case storefront
        // swiftlint:disable identifier_name
        case _verticalImageURL,
             _horizontalImageURL
        case _containerURL
        // swiftlint:enable identifier_name
        case launchArguments,
             isFavourited,
             lastLaunched
        case isSettingsAutomatic,
             settingsOverride
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(installationState, forKey: .installationState)
        try container.encodeIfPresent(storefront, forKey: .storefront)
        try container.encodeIfPresent(_verticalImageURL, forKey: ._verticalImageURL)
        try container.encodeIfPresent(_horizontalImageURL, forKey: ._horizontalImageURL)
        try container.encodeIfPresent(_containerURL, forKey: ._containerURL)
        try container.encode(launchArguments, forKey: .launchArguments)
        try container.encode(isFavourited, forKey: .isFavourited)
        try container.encodeIfPresent(lastLaunched, forKey: .lastLaunched)
        try container.encode(isSettingsAutomatic, forKey: .isSettingsAutomatic)
        try container.encode(settingsOverride, forKey: .settingsOverride)
    }
}

// note that merges should only be performed with the `identicalIgnoredKeys` requirement enforced.
extension Game: Mergeable {
    typealias MergeKeys = CodingKeys
    
    static var ignoredMergeKeys: Set<CodingKeys> {
        [.id, .title, .storefront]
    }
    
    var mergeRules: [AnyMergeRule] {[
        .init(\Game.installationState, forCodingKey: .installationState, strategy: { max($0, $1) }),
        .init(\Game._verticalImageURL, forCodingKey: ._verticalImageURL, strategy: { $1 ?? $0 }),
        .init(\Game._horizontalImageURL, forCodingKey: ._horizontalImageURL, strategy: { $1 ?? $0 }),
        .init(\Game._containerURL, forCodingKey: ._containerURL, strategy: { $0 ?? $1 }),
        .init(\Game.launchArguments, forCodingKey: .launchArguments, strategy: { Array(Set($0 + $1)) }),
        .init(\Game.isFavourited, forCodingKey: .isFavourited, strategy: { $0 || $1 }),
        // A hand-made choice outlives a merge: if either side has taken the wheel, it stays
        // taken, and the two sets of values are overlaid rather than one replacing the other.
        .init(\Game.isSettingsAutomatic, forCodingKey: .isSettingsAutomatic, strategy: { $0 && $1 }),
        .init(\Game.settingsOverride, forCodingKey: .settingsOverride, strategy: { $0.overlaid(with: $1) }),
        AnyMergeRule(\Game.lastLaunched, forCodingKey: .lastLaunched) { current, new in
            guard current != nil || new != nil else { return current }
            return max(current ??  .distantPast, new ?? .distantPast)
        }
    ]}
}

struct AnyGame: Codable, Equatable {
    let base: Game

    init(_ base: Game) {
        self.base = base
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Game.CodingKeys.self)
        let storefront = try container.decodeIfPresent(Game.Storefront.self, forKey: .storefront)

        self.base = try {
            switch storefront {
            case .epicGames:    try EpicGamesGame(from: decoder)
            case .gog:          try GOGGame(from: decoder)
            case .steam:        try SteamGame(from: decoder)
            case .local:        try LocalGame(from: decoder)
            case nil:           try Game(from: decoder)
            }
        }()
    }

    func encode(to encoder: Encoder) throws {
        try base.encode(to: encoder)
    }
}

@MainActor func placeholderGame<T: Game>(type: T.Type) -> T {
    if type is EpicGamesGame.Type, !Legendary.isSignedIn {
        assertionFailure("""
            You must sign in through a live instance of the app before calling placeholderGame(type:).
            """)
    }

    guard let game = GameDataStore.shared.library.first(where: { ($0 as? T) != nil }) as? T else {
        fatalError("""
            No games are in your library of type \(T.self) to populate placeholderGame.
            """)
    }

    return game as T
}
