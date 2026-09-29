//
//  WineInterface+Container.swift
//  Mythic
//
//  Created by vapidinfinity (esi) on 30/10/2023.
//

// Copyright © 2023-2025 vapidinfinity

import Foundation
import OSLog

extension Wine {
    final class Container: Identifiable, ObservableObject { // FIXME: final.. for now
        private static let log: Logger = .custom(category: "Wine.Container")

        /// Saves the container properties to disk.
        func saveProperties() {
            let encoder = PropertyListEncoder()
            do {
                let data = try encoder.encode(self)
                try data.write(to: propertiesFile)
            } catch {
                Wine.Container.log.error("Error writing properties for container \"\(self.name)\" (\(self.url.prettyPath))")
            }
        }

        /// Initialise a new container, checking if a container at the given URL already exists.
        init(name: String, url: URL, id: UUID = .init(), settings: Container.Settings) {
            let existingContainer = try? Container(knownURL: url)

            self.name = existingContainer?.name ?? name
            self.url = url
            self.id = existingContainer?.id ?? id
            self.settings = existingContainer?.settings ?? settings

            saveProperties()
        }

        /// Initialise a container from an existing URL
        init(knownURL: URL) throws {
            guard containerExists(at: knownURL) else {
                Wine.Container.log.warning("Attempted to initialise nonexistent container from known URL.")
                throw Container.DoesNotExistError()
            }

            let object = try getContainerObject(at: knownURL)

            self.name = object.name
            self.url = knownURL
            self.id = object.id
            self.settings = object.settings
        }

        /// Synthesize a container object from a URL.
        convenience init(createFrom url: URL) {
            self.init(name: url.lastPathComponent, url: url, settings: .init())
        }

        var name: String { didSet { saveProperties() } }
        var url: URL
        var id: UUID
        var settings: Container.Settings { didSet { saveProperties() } }

        var propertiesFile: URL { url.appending(path: "Properties.plist") }
    }
}

extension Wine.Container: Equatable {
    static func == (lhs: Wine.Container, rhs: Wine.Container) -> Bool {
        return (lhs.url == rhs.url && lhs.id == rhs.id)
    }
}

extension Wine.Container: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(url)
        hasher.combine(id)
    }
}

extension Wine.Container: Codable {
    enum CodingKeys: String, CodingKey {
        case name
        case url
        case id
        case settings
    }
}

extension Wine.Container {
    struct Process: Identifiable {
        var id: Int { pid }
        var imageName: String
        var pid: Int
        var sessionName: String?
        var sessionNumber: Int?
        var memoryUsage: Int?
    }

    struct Settings: Hashable, Equatable {
        var metalHUD: Bool
        var msync: Bool
        var retinaMode: Bool
        var dxvk: Bool
        var dxvkAsync: Bool
        var windowsVersion: Wine.WindowsVersion
        /// Stored, but no longer what decides the prefix's DPI — see ``displayScaling``. Kept
        /// so containers written before that decode, and because a slider for it is still on
        /// the backlog.
        var scaling: Int

        /// The DPI that has to accompany ``retinaMode``.
        ///
        /// Not independent of it, which is how this went wrong. Wine's macOS driver reports
        /// the display at its backing resolution with Retina Mode on and at logical size with
        /// it off, so 192 belongs to the first and 96 to the second. A container carrying 192
        /// with Retina off tells applications the display is 2× while handing them a 1×
        /// desktop, and a DPI-aware game then sizes its window for twice the pixels it is
        /// going to get — which is the small window Horizon Chase Turbo kept opening in,
        /// every time, after Retina Mode was defaulted off and the 192 that only made sense
        /// with it on stayed behind.
        var displayScaling: Int { Self.displayScaling(forRetinaMode: retinaMode) }

        /// The DPI that has to accompany a given Retina Mode.
        ///
        /// A function as well as a property because the caller that matters most doesn't have
        /// a `Settings` to ask: ``Wine/toggleRetinaMode(containerURL:toggle:)`` is handed a
        /// bare `Bool`. This rule had three copies — there, in `Provisioner.apply`'s
        /// `expectedScaling`, and here — and the small window came back the moment they
        /// stopped agreeing. One function, three call sites.
        static func displayScaling(forRetinaMode retinaMode: Bool) -> Int {
            retinaMode ? 192 : 96
        }
        var avx2: Bool

        /// Whether a fullscreen game gets the display to itself.
        ///
        /// Wine's `CaptureDisplaysForFullscreen`. With it off — Wine's default and now ours — a
        /// "fullscreen" game is a window the size of the screen, with the macOS menu bar and
        /// the Dock drawn on top of it. That is not a game ignoring its own settings; it is the
        /// driver never taking the display, and clicking into the game raises the window and
        /// makes it look fixed, which is how it hides.
        ///
        /// **Off, having been tried on.** Turning it on does exactly what it says: games that
        /// ask for fullscreen cover the screen properly. It also blanks every other attached
        /// display for as long as the game is fullscreen, because capturing a display captures
        /// all of them — there is no "just this one". On a two-monitor desk that trade is worse
        /// than the menu bar: a browser or a guide on the second screen going black is a real
        /// loss, and the Dock over a corner of the game is an annoyance. Windows behaves the
        /// other way, which is why this was worth trying.
        ///
        /// Kept as a setting rather than removed, per game, for anyone who would rather have
        /// the screen than the second monitor.
        var captureDisplaysForFullscreen: Bool

        /// wined3d's command-stream thread, which Wine calls CSMT.
        ///
        /// On by default because that is Wine's default and it is usually faster. Off is the
        /// first thing to try when a game using wined3d crashes or hangs: it moves the GL
        /// work back onto the thread that asked for it, which both shortens the call chains
        /// through 32-on-64's thunks and removes a whole class of races.
        var commandStreamThread: Bool

        /// Which Wine build runs this container, as a ``Runtime/id``.
        ///
        /// `nil` means the bundled engine, which is what every container created before
        /// runtimes existed will decode as.
        ///
        /// - Important: A container is effectively married to its runtime. Wine migrates a
        ///   prefix forward on first run and has no downgrade path, so moving a container
        ///   from Wine 11 back to the 7.7 engine will not work — see
        ///   ``Runtime/isCompatible(withPrefixCreatedBy:)``.
        var runtimeID: String?

        init(metalHUD: Bool = false,
             msync: Bool = true,
             // Off, like every game's profile asks for. On, Wine gives the game a desktop at
             // the display's full backing resolution, and one that doesn't ask for that draws
             // into a corner of it with the other displays blanked.
             retinaMode: Bool = false,
             dxvk: Bool = false,
             dxvkAsync: Bool = false,
             windowsVersion: Wine.WindowsVersion = .win11,
             scaling: Int = 96,
             avx2: Bool = true,
             captureDisplaysForFullscreen: Bool = false,
             commandStreamThread: Bool = true,
             runtimeID: String? = nil) {
            self.runtimeID = runtimeID
            self.metalHUD = metalHUD
            self.msync = msync
            self.retinaMode = retinaMode
            self.dxvk = dxvk
            self.dxvkAsync = dxvkAsync
            self.windowsVersion = windowsVersion
            self.scaling = scaling
            self.captureDisplaysForFullscreen = captureDisplaysForFullscreen
            self.commandStreamThread = commandStreamThread
            self.avx2 = {
                if #available(macOS 15.0, *) {
                    return avx2
                } else {
                    return false
                }
            }()
        }
    }

    enum Scope: String, CaseIterable {
        case individual
        case global
    }
}

extension Wine.Container.Settings: Codable {
    enum CodingKeys: String, CodingKey {
        case metalHUD
        case msync
        case retinaMode
        case dxvk
        case dxvkAsync
        case windowsVersion
        case scaling
        case avx2
        case captureDisplaysForFullscreen
        case commandStreamThread
        case runtimeID
    }

    init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)

        self.metalHUD = try container.decodeIfPresent(Bool.self, forKey: .metalHUD) ?? self.metalHUD
        self.msync = try container.decodeIfPresent(Bool.self, forKey: .msync) ?? self.msync
        self.retinaMode = try container.decodeIfPresent(Bool.self, forKey: .retinaMode) ?? self.retinaMode
        self.dxvk = try container.decodeIfPresent(Bool.self, forKey: .dxvk) ?? self.dxvk
        self.dxvkAsync = try container.decodeIfPresent(Bool.self, forKey: .dxvkAsync) ?? self.dxvkAsync
        self.windowsVersion = try container.decodeIfPresent(Wine.WindowsVersion.self, forKey: .windowsVersion) ?? self.windowsVersion
        self.scaling = try container.decodeIfPresent(Int.self, forKey: .scaling) ?? self.scaling
        self.avx2 = try container.decodeIfPresent(Bool.self, forKey: .avx2) ?? self.avx2
        // Absent from every container written before this existed, and from every container
        // written while it briefly defaulted to `true` — in both cases they take the `init()`
        // default below, and the prefix's registry is rewritten before the next launch anyway.
        self.captureDisplaysForFullscreen = try container.decodeIfPresent(Bool.self,
                                                                          forKey: .captureDisplaysForFullscreen)
            ?? self.captureDisplaysForFullscreen
        self.commandStreamThread = try container.decodeIfPresent(Bool.self, forKey: .commandStreamThread) ?? self.commandStreamThread
        self.runtimeID = try container.decodeIfPresent(String.self, forKey: .runtimeID)
    }
}

extension Wine.Container {
    struct DoesNotExistError: LocalizedError {
        var errorDescription: String? = String(localized: """
            Attempted to access a container that doesn't exist.
            If relevant, please verify that the container is set correctly.
            """)
    }

    struct UnableToBootError: LocalizedError {
        var errorDescription: String? = String(localized: "Container unable to boot.") // TODO: add reason if possible
    }

    struct AlreadyExistsError: LocalizedError {
        var errorDescription: String? = String(localized: "Attempted to access a container that already exists.")
    }
}
