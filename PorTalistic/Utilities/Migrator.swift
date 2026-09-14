//
//  Migrator.swift
//  Mythic
//
//  Created by vapidinfinity (esi) on 24/4/2025.
//

// Copyright © 2023-2025 vapidinfinity

import Foundation
import OSLog

// ‼️ This code should be removed before v1.0.0
// warning mediocre code lies ahead the actual good code lies within the app
// TODO: remove migration for v0.1.0 & v0.3.2
/// Migrate redundant data structures to newer data structures.
final class Migrator {
    private static let log: Logger = .custom(category: "Migrator")
    private static let containerQueue = DispatchQueue(label: "containerMigration")

    static func fullMigration() {
        // First, and synchronously. Everything below it reads data from a path derived from
        // the app's own name and identifier, and this is the step that moves that data to
        // where the renamed app will look.
        v0_6_0.migrate()

        v0_1_0.migrate()
        v0_3_2.migrate()
        v0_5_0.migrate()
    }

    /// The rebrand from Mythic to PorTalistic.
    ///
    /// Renaming an app moves its data, because both locations are derived rather than chosen:
    /// `Bundle.appHome` is `Application Support/<CFBundleDisplayName>` and `Bundle.appContainer`
    /// is `Library/Containers/<bundle identifier>`. `UserDefaults` is keyed by the identifier
    /// too. So without this step the renamed app starts up signed out of Epic and GOG, with an
    /// empty library, no containers, and several gigabytes of engine and runtimes to fetch
    /// again — while all of it sits on disk under the old name.
    ///
    /// Written to be idempotent and to survive being interrupted: every step moves items one
    /// at a time and skips anything already at the destination, so a half-finished migration
    /// finishes on the next launch rather than getting stuck or clobbering what arrived first.
    struct v0_6_0 { // swiftlint:disable:this type_name
        private init() {}

        static let previousBundleIdentifier = "xyz.blackxfiied.Mythic"
        static let previousApplicationSupportName = "Mythic"

        static func migrate() {
            // Defaults first: the container paths that the folder move has to rewrite are
            // stored in them, and reading them afterwards would read the new, empty domain.
            migrateUserDefaultsDomain()
            migrateApplicationSupportFolder()
            migrateContainerFolder()
        }

        // MARK: - Defaults

        /// Copy the old bundle identifier's defaults domain into this one.
        ///
        /// Only keys this domain doesn't already have, so running twice can't undo a change
        /// made after the first run — and so a user who has already set something in the
        /// renamed app keeps their newer value.
        static func migrateUserDefaultsDomain() {
            guard Bundle.main.bundleIdentifier != previousBundleIdentifier else { return }
            guard let previous = UserDefaults.standard.persistentDomain(forName: previousBundleIdentifier),
                  !previous.isEmpty else { return }

            let current = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
            var merged = current
            var copied = 0

            for (key, value) in previous where current[key] == nil {
                // Apple's own keys travel with the domain and mean nothing here.
                guard !key.hasPrefix("NS"), !key.hasPrefix("Apple"), !key.hasPrefix("com.apple") else { continue }

                merged[key] = value
                copied += 1
            }

            guard copied > 0 else { return }

            UserDefaults.standard.setPersistentDomain(merged, forName: Bundle.main.bundleIdentifier ?? "")
            log.notice("Rebrand: carried \(copied, privacy: .public) settings over from the previous bundle identifier")
        }

        // MARK: - Application Support

        /// Move `Application Support/Mythic` to whatever the app is called now.
        ///
        /// Deliberately not via `Bundle.appHome`, which *creates* the directory when asked for
        /// it — touching it first would leave an empty folder at the destination and make this
        /// look like it had already run.
        static func migrateApplicationSupportFolder() {
            guard let applicationSupport = FileLocations.userApplicationSupport else { return }

            let currentName = Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String ?? ""
            guard !currentName.isEmpty, currentName != previousApplicationSupportName else { return }

            let source = applicationSupport.appending(path: previousApplicationSupportName)
            let destination = applicationSupport.appending(path: currentName)

            moveContents(of: source, to: destination, describing: "application support")
        }

        // MARK: - Containers

        /// Move the Wine prefixes, then repair every path that pointed into them.
        ///
        /// The order matters and the reason is easy to miss: `Wine.containerURLs` filters out
        /// any URL whose container no longer exists, so reading or writing that list between
        /// the move and the rewrite would silently drop every container the user has.
        static func migrateContainerFolder() {
            guard let library = FileLocations.userLibrary,
                  let identifier = Bundle.main.bundleIdentifier,
                  identifier != previousBundleIdentifier else { return }

            let containers = library.appending(path: "Containers")
            let source = containers.appending(path: previousBundleIdentifier)
            let destination = containers.appending(path: identifier)

            guard FileManager.default.fileExists(atPath: source.path) else { return }

            moveContents(of: source, to: destination, describing: "containers")

            rewriteStoredContainerURLs(from: source, to: destination)
        }

        /// Rewrite the stored container list, bypassing `Wine.containerURLs`' own filtering.
        private static func rewriteStoredContainerURLs(from source: URL, to destination: URL) {
            guard let stored = try? UserDefaults.standard.decodeAndGet([URL].self, forKey: "containerURLs") else { return }

            let rewritten = stored.map { url -> URL in
                guard url.path.hasPrefix(source.path) else { return url }
                return .init(filePath: url.path.replacingOccurrences(of: source.path, with: destination.path))
            }

            guard rewritten != stored else { return }

            try? UserDefaults.standard.encodeAndSet(rewritten, forKey: "containerURLs")
            log.notice("Rebrand: repointed \(rewritten.count, privacy: .public) container URLs")
        }

        // MARK: - Moving

        /// Move everything in `source` into `destination`, one item at a time.
        ///
        /// Item-by-item rather than moving the folder, because `destination` may already exist
        /// — anything that asked for `Bundle.appHome` creates it — and because it makes the
        /// whole thing resumable. Anything already at the destination is left alone: it is
        /// either newer or identical, and neither is worth overwriting.
        private static func moveContents(of source: URL, to destination: URL, describing what: String) {
            guard FileManager.default.fileExists(atPath: source.path),
                  let contents = try? FileManager.default.contentsOfDirectory(atPath: source.path),
                  !contents.isEmpty else { return }

            do {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            } catch {
                log.error("Rebrand: couldn't create the new \(what, privacy: .public) folder: \(error.localizedDescription)")
                return
            }

            var moved = 0

            for item in contents {
                let from = source.appending(path: item)
                let to = destination.appending(path: item)

                guard !FileManager.default.fileExists(atPath: to.path) else { continue }

                do {
                    try FileManager.default.moveItem(at: from, to: to)
                    moved += 1
                } catch {
                    log.error("Rebrand: couldn't move \(item, privacy: .public): \(error.localizedDescription)")
                }
            }

            if moved > 0 {
                log.notice("Rebrand: moved \(moved, privacy: .public) items into the new \(what, privacy: .public) folder")
            }
        }
    }

    struct v0_1_0 { // swiftlint:disable:this type_name
        private init() {}

        static func migrate() {
            Task(operation: { Migrator.v0_1_0.migrateFromAllBottlesFormat() })
        }

        /// Migrate redundant bottle format.
        /// Data migration from versions v0.1.1-alpha or earlier.
        static func migrateFromAllBottlesFormat() {
            // Determines eligibility by searching for redundant UserDefaults key "allBottles".
            guard let data = UserDefaults.standard.data(forKey: "allBottles"),
                  let decodedData = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: [String: Any]] else {
                return
            }

            containerQueue.sync {
                log.notice("Older bottle format detected, commencing bottle management system migration")

                var convertedBottles: [Wine.Container] = .init()

                for (index, (name, bottle)) in decodedData.enumerated() {
                    guard let urlArray = bottle["url"] as? [String: String], // unable to cast directly to URL, they're stored as arrays for whatever reason
                          let relativeURL = urlArray["relative"],
                          let url: URL = .init(string: relativeURL.removingPercentEncoding ?? relativeURL) else {
                        return
                    }

                    var settings: Wine.Container.Settings = .init()
                    guard let oldSettings = bottle["settings"] as? [String: Bool] else {
                        log.warning("Unable to read old bottle settings; using default")
                        continue
                    }

                    settings.metalHUD = oldSettings["metalHUD"] ?? settings.metalHUD
                    settings.msync = oldSettings["msync"] ?? settings.msync
                    settings.retinaMode = oldSettings["retinaMode"] ?? settings.retinaMode

                    convertedBottles.append(.init(name: name, url: url, settings: settings))
                    Wine.containerURLs.insert(url)

                    log.notice("converted \(url.prettyPath) (\(index + 1)/\(decodedData.count))")
                }

                log.notice("Bottle management system migration complete.")
                UserDefaults.standard.removeObject(forKey: "allBottles")
            }
        }
    }

    // MARK: - v0.3.2 or earlier
    /// Data migration from v0.3.2 or earlier
    struct v0_3_2 { // swiftlint:disable:this type_name
        private init() {}

        static func migrate() {
            Task(operation: { Migrator.v0_3_2.migrateBottleSchemeToContainerSchemeIfNecessary() })
            Task(operation: { await Migrator.v0_3_2.updateContainerScalingIfNecessary() })
            Task(operation: { Migrator.v0_3_2.migrateEpicFolderNaming() })
        }

        /// Migrate Bottle → Container naming scheme.
        /// Data migration from versions v0.3.2 and below.
        /// This must be ran **before** the "launchCount" UserDefaults key is appended to.
        static func migrateBottleSchemeToContainerSchemeIfNecessary() {
            guard let appContainer = Bundle.appContainer else { return }
            let oldScheme = appContainer.appending(path: "Bottles")
            let newScheme = appContainer.appending(path: "Containers")

            // determine eligibility by checking if old scheme exists at path
            guard FileManager.default.fileExists(atPath: oldScheme.path) else { return }
            log.notice("Commencing bottle → container scheme migration.")

            containerQueue.sync {
                do {
                    try FileManager.default.moveItem(at: oldScheme, to: newScheme)

                    if let contents = try? FileManager.default.contentsOfDirectory(at: newScheme, includingPropertiesForKeys: nil) {
                        for containerURL in contents {
                            log.notice("Migrating container object: \(String(describing: try? Wine.Container(knownURL: containerURL)))")
                        }
                    }

                    // Migrate bottleURLs to containerURLs
                    if let bottleURLs = try? UserDefaults.standard.decodeAndGet([URL].self, forKey: "bottleURLs") {
                        let containerURLs = bottleURLs.map { bottleURL -> URL in
                            let currentPath = bottleURL.path(percentEncoded: false)
                            if currentPath.contains(oldScheme.path(percentEncoded: false)) {
                                let newPath = currentPath.replacingOccurrences(of: oldScheme.path(percentEncoded: false),
                                                                               with: newScheme.path(percentEncoded: false))
                                log.notice("Migrating bottle (modifying bottle URL from \(bottleURL) to \(newPath))...")
                                return URL(filePath: newPath)
                            } else {
                                return bottleURL
                            }
                        }

                        do {
                            try UserDefaults.standard.encodeAndSet(containerURLs, forKey: "containerURLs")
                            UserDefaults.standard.removeObject(forKey: "bottleURLs")
                        } catch {
                            log.error("Unable to re-encode default 'bottleURLs' as 'containerURLs': \(error.localizedDescription)")
                        }
                    }

                    // Game-specific bottleURL migration
                    UserDefaults.standard.dictionaryRepresentation() // FIXME: may update in the future with a PersistentGameData UD dictionary
                        .filter { $0.key.hasSuffix("_bottleURL") }
                        .forEach { key, value in
                            guard let currentURL = value as? URL else { return }
                            let currentPath = currentURL.path(percentEncoded: false)
                            guard FileManager.default.fileExists(atPath: currentPath) else { return }

                            let filteredURL: URL
                            if currentPath.contains(oldScheme.path(percentEncoded: false)) {
                                let newPath = currentPath.replacingOccurrences(of: oldScheme.path(percentEncoded: false),
                                                                               with: newScheme.path(percentEncoded: false))
                                filteredURL = URL(filePath: newPath)
                            } else {
                                filteredURL = currentURL
                            }

                            let targetGameID = key.replacingOccurrences(of: "_bottleURL", with: "")
                            log.notice("Migrating game \(targetGameID)'s container URL...")
                            UserDefaults.standard.set(filteredURL, forKey: key.replacingOccurrences(of: "_bottleURL", with: "_containerURL"))
                            UserDefaults.standard.removeObject(forKey: key)
                        }

                    log.notice("Container renaming complete.")
                } catch {
                    log.error("Unable to rename Bottles to Containers: \(error.localizedDescription).")
                }
            }
        }

        /// Updates containers without a default scale set.
        /// Data migration from versions v0.3.2 and below.
        static func updateContainerScalingIfNecessary() async {
            log.info("Migrating container scaling")
            // If scaling value is 0, it does not have a default scale set.
            for container in Wine.containerObjects where container.settings.scaling == 0 {
                let defaultScale = Wine.Container.Settings().scaling

                do {
                    try await Wine.setDisplayScaling(containerURL: container.url, dpi: defaultScale)
                    container.settings.scaling = defaultScale
                } catch {
                    log.error("Unable to migrate scaling for container at URL \(container.url.prettyPath): \(error)")
                }
            }
            log.info("Migrated container scaling.")
        }

        /// Rename Legendary configuration folder.
        /// Data migration from versions v0.3.2 and below.
        static func migrateEpicFolderNaming() {
            log.info("Migrating epic folder naming")
            let legendaryOldConfig: URL = Bundle.appHome!.appending(path: "Config")
            if FileManager.default.fileExists(atPath: legendaryOldConfig.path) {
                try? FileManager.default.moveItem(at: legendaryOldConfig, to: Legendary.configurationFolder)
            }
            log.info("Migrated epic folder naming.")
        }
    }

    // MARK: - v0.5.0 or earlier
    /// Data migration from v0.5.0 or earlier
    struct v0_5_0 { // swiftlint:disable:this type_name
        private init() {}

        static func migrate() {
            Task(operation: { await Migrator.v0_5_0.migrateFavouriteGames() })
            Task(operation: { await Migrator.v0_5_0.migrateLocalGamesLibrary() })
            Task(operation: { await Migrator.v0_5_0.migrateContainerURLs() })
            Task(operation: { await Migrator.v0_5_0.migrateLaunchArguments() })
            Task(operation: { await Migrator.v0_5_0.migrateImageURLs() })
            Task(operation: { await Migrator.v0_5_0.migrateWideImageURLs() })
        }

        // TODO: Migrate localGamesLibrary
        // recentlyPlayed will not be migrated.

        static func migrateFavouriteGames() async {
            log.notice("Migrating favourite game storage.")

            if let oldFavouriteGames: [String] = UserDefaults.standard.stringArray(forKey: "favouriteGames") {
                try? await GameDataStore.shared.refreshFromStorefronts()

                await MainActor.run {
                    for id in oldFavouriteGames where GameDataStore.shared.library.contains(where: { $0.id == id }) {
                        let targetGame = GameDataStore.shared.library.first(where: { $0.id == id })!
                        targetGame.isFavourited = true
                    }
                }

                UserDefaults.standard.removeObject(forKey: "favouriteGames")
            }
        }

        static func migrateLocalGamesLibrary() async {
            log.notice("Migrating local game library storage.")

            guard let data = UserDefaults.standard.data(forKey: "localGamesLibrary") else { return }
            guard let underlyingPlist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[[String: Any]]],
                  let properties = underlyingPlist.first else { return }

            for (index, item) in properties.enumerated() {
                guard let id = item["id"] as? String,
                      let title = item["title"] as? String,
                      let path = item["_path"] as? String,
                      let fetchedPlatform = item["_platform"] as? String,
                      let platform: Game.Platform = .allCases.first(where: { $0.description == fetchedPlatform }) else {
                    var itemDump: String = .init(); dump(item, to: &itemDump)
                    log.notice("""
                       Item found in local games library storage was malformed and could not be migrated.
                       Contents: \(itemDump)
                       """)
                    continue
                }

                let propertiesCount = properties.count
                await MainActor.run {
                    let game: LocalGame = .init(id: id,
                                                title: title,
                                                installationState: .installed(
                                                    location: .init(filePath: path),
                                                    platform: platform)
                    )

                    GameDataStore.shared.library.insert(game)
                    log.notice("Successfully migrated local game \(game.title) from local games library storage. (\(index + 1)/\(propertiesCount))")
                }
            }

            UserDefaults.standard.removeObject(forKey: "localGamesLibrary")
        }

        static func migrateContainerURLs() async {
            if UserDefaults.standard.dictionaryRepresentation()
                .contains(where: { $0.key.hasSuffix("_containerURL") }) {
                try? await GameDataStore.shared.refreshFromStorefronts()
            }

            log.notice("Migrating game container URL storage.")

            for (key, url) in UserDefaults.standard.dictionaryRepresentation() where key.hasSuffix("_containerURL") {
                guard let url = url as? URL else { continue }
                let targetGameID: String = key.replacingOccurrences(of: "_containerURL", with: "")

                // check not for existence, but if it's in containerURLs
                // otherwise, it's a dead reference.
                guard Wine.containerURLs.contains(url) else {
                    log.warning("Container URL for game \(targetGameID) no longer exists. Skipping.")
                    continue
                }

                await MainActor.run {
                    guard let targetGame = GameDataStore.shared.library.first(where: { $0.id == targetGameID }) else {
                        log.warning("Game with ID \(targetGameID) not found in store, skipping migration.")
                        return
                    }

                    targetGame.containerURL = url
                }

                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        static func migrateLaunchArguments() async {
            if UserDefaults.standard.dictionaryRepresentation()
                .contains(where: { $0.key.hasSuffix("_launchArguments") }) {
                try? await GameDataStore.shared.refreshFromStorefronts()
            }

            log.notice("Migrating game launch argument storage.")

            for (key, arguments) in UserDefaults.standard.dictionaryRepresentation() where key.hasSuffix("_launchArguments") {
                guard let arguments = arguments as? [String] else { continue }

                let targetGameID: String = key.replacingOccurrences(of: "_launchArguments", with: "")
                await MainActor.run {
                    guard let targetGame = GameDataStore.shared.library.first(where: { $0.id == targetGameID }) else {
                        log.warning("Game with ID \(targetGameID) not found in store, skipping migration.")
                        return
                    }
                    if targetGame.launchArguments.isEmpty {
                        targetGame.launchArguments = arguments
                    } else {
                        log.warning("Game \(targetGame) already has launch arguments set, skipping migration.")
                    }
                }

                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        static func migrateImageURLs() async {
            if UserDefaults.standard.dictionaryRepresentation()
                           .contains(where: { $0.key.hasSuffix("_imageURL") }) {
                           try? await GameDataStore.shared.refreshFromStorefronts()
                       }

            log.notice("Migrating game vertical image storage.")

            for (key, url) in UserDefaults.standard.dictionaryRepresentation() where key.hasSuffix("_imageURL") {
                guard let url = url as? URL else { continue }

                let targetGameID: String = key.replacingOccurrences(of: "_imageURL", with: "")
                await MainActor.run {
                    guard let targetGame = GameDataStore.shared.library.first(where: { $0.id == targetGameID }) else {
                        log.warning("Game with ID \(targetGameID) not found in store, skipping migration.")
                        return
                    }

                    // imageURLs must have been custom if stored in UD
                    // so it's safe to directly append to underlying property
                    targetGame._verticalImageURL = url
                }

                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        static func migrateWideImageURLs() async {
            if UserDefaults.standard.dictionaryRepresentation()
                .contains(where: { $0.key.hasSuffix("_wideImageURL") }) {
                try? await GameDataStore.shared.refreshFromStorefronts()
            }

            log.notice("Migrating game horizontal image storage.")

            for (key, url) in UserDefaults.standard.dictionaryRepresentation() where key.hasSuffix("_wideImageURL") {
                guard let url = url as? URL else { continue }

                let targetGameID: String = key.replacingOccurrences(of: "_wideImageURL", with: "")
                await MainActor.run {
                    guard let targetGame = GameDataStore.shared.library.first(where: { $0.id == targetGameID }) else {
                        log.warning("Game with ID \(targetGameID) not found in store, skipping migration.")
                        return
                    }

                    // wideImageURLs must have been custom if stored in UD
                    // so it's safe to directly append to underlying property
                    targetGame._horizontalImageURL = url
                }

                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }
}
