//
//  EpicGamesGameInstallationView.swift
//  Mythic
//
//  Created by vapidinfinity (esi) on 27/11/2025.
//

// Copyright © 2023-2025 vapidinfinity

import Foundation
import SwiftUI
import OSLog

struct EpicGamesGameInstallationView: View {
    @Binding var game: EpicGamesGame
    @Binding var isPresented: Bool

    @Bindable private var operationManager: GameOperationManager = .shared
    @AppStorage("installBaseURL") private var baseURL: URL = Bundle.appGames!

    @State private var isImageEmpty: Bool = true

    @State private var isInstallLocationFileImporterPresented: Bool = false

    @State var platform: Game.Platform = .macOS

    @State var installSizeInBytes: Int64?
    var availableSpaceInBytes: Int64? {
        // The volume the game is going to, not the one the app lives on. This asked about
        // `Bundle.appHome` — the internal drive — so choosing an external disk meant the
        // free-space check was answered by a completely different filesystem: plenty of room
        // reported, and then legendary refusing the install for lack of space on the drive
        // that actually mattered. GOG's sheet has always asked about `baseURL`.
        let filesystemAttributes = try? FileManager.default.attributesOfFileSystem(forPath: baseURL.path)
        return (filesystemAttributes?[.systemFreeSize] as? Int64)
    }
    @State private var isFreeSpaceAlertPresented: Bool = false

    @State private var isRetrievingSupportedPlatforms: Bool = false
    @State private var supportedPlatforms: [Game.Platform]?

    // epic-specific variables
    @State var optionalPacks: [String: String] = .init()
    @State var selectedOptionalPackIDs: Set<String> = .init()
    @State var fetchingOptionalPacks: Bool = false

    /// The probe currently asking legendary how big the download is, and which generation of
    /// the question it is answering.
    @State private var metadataProbe: Task<Void, Never>?
    @State private var probeGeneration: Int = 0

    /// Why the last attempt to start the installation failed, if it did.
    @State private var installationError: Error?

    /// The Install button's own busy state.
    ///
    /// It used to share `fetchingOptionalPacks` with the size lookup, which crossed two
    /// unrelated things: pressing Install wrote the probe's flag, and `OperationButton`'s
    /// `defer` cleared it again the moment the action returned — re-enabling the button and
    /// stopping the spinner while a probe was still running. It also meant that pressing
    /// Install and having it fail looked identical to nothing happening at all.
    @State private var isStartingInstallation: Bool = false

    /// Why there is no download size, when there isn't one.
    ///
    /// Blank was the whole of the report: a game that legendary had refused to answer about
    /// looked exactly like one whose size had simply not arrived yet.
    @State private var probeFailure: String?

    /// Ask legendary what this game would cost to download, for the platform now selected.
    ///
    /// Two faults lived in the five lines this replaced, and between them they are why some
    /// games showed no download size at all.
    ///
    /// The sheet opens with `platform` still at its default, which is a guess, and `.onAppear`
    /// fired a probe for that guess straight away. Only afterwards does the `.task` on the
    /// picker work out which platforms the game actually has and set `platform` to a real one —
    /// and the `.onChange` that fires from *that* was rejected by `guard !fetchingOptionalPacks`
    /// while the first probe was still running. So the request that got dropped was reliably the
    /// only correct one, and what stayed on screen was legendary's answer about a build that
    /// does not exist. Whether it happened at all came down to which of the two landed first,
    /// which is why it affected some games and not others.
    ///
    /// So: nothing is asked until the platform is known to be one the game offers, and a new
    /// question replaces the one in flight rather than being thrown away. Cancelling the old
    /// probe matters for more than tidiness — each one is a `legendary` process holding the
    /// installed-data lock, and two of them race each other for it.
    private func spawnOptionalPacksFetchTask() {
        // Only waits for the platforms to have been worked out — it does not require the
        // selection to be among them. Requiring that meant a game whose platform list came back
        // empty, or whose selection had not been corrected, was never asked about at all: no
        // size, no spinner, nothing.
        guard supportedPlatforms != nil else { return }

        metadataProbe?.cancel()
        probeGeneration += 1
        let generation = probeGeneration

        // Cleared now rather than when the answer comes back: left until then, the reason the
        // *last* platform had no size sits on screen beside the spinner of the question that
        // replaced it.
        probeFailure = nil

        let probe = Task(priority: .userInitiated) { [game, platform] in
            withAnimation { fetchingOptionalPacks = true }

            var failure: String?
            let fetched: (installSize: Int64?, optionalPacks: [String: String])?
            do {
                fetched = try await Legendary.fetchPreInstallationMetadata(game: game, platform: platform)
                failure = nil
            } catch {
                // Said out loud, and shown. This was a `try?`, so a game legendary had refused
                // to answer about gave no indication anywhere — not in the interface, not in
                // the log. The lock is named specifically because it is the likely one and it
                // is not a fault: something else is simply downloading.
                Logger.app.error("""
                    Couldn't read the download size for \(game.description, privacy: .public) \
                    on \(platform.description, privacy: .public): \(error.localizedDescription)
                    """)

                failure = (error as? Legendary.InstalledDataLockError)?.errorDescription
                    ?? String(localized: "Download size unavailable.")
                fetched = nil
            }

            // A newer question has been asked; its answer is the one that belongs on screen,
            // and its spinner is the one running.
            guard generation == probeGeneration else { return }

            (installSizeInBytes, optionalPacks) = fetched ?? (nil, .init())
            probeFailure = failure
            withAnimation { fetchingOptionalPacks = false }
        }
        metadataProbe = probe

        // No watchdog here. There was one, set at thirty seconds, and it was a mistake: it
        // existed for the old probe, which ran `legendary install` and could block at a prompt
        // forever. `legendary info` cannot block like that and is bounded by its own process
        // timeout — but it does start by renewing the Epic login, and on a slow connection that
        // alone can take longer than thirty seconds. So the watchdog killed working lookups and
        // reported them as "Download size unavailable."
    }

    var body: some View {
        VStack { // wrap in VStack to prevent padding from callers being applied within the view
            GameSheetHeader(game: game, action: String(localized: "Install")) {
                VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                    if !optionalPacks.isEmpty {
                        Text("(Selective downloads supported.)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        Form {
                            ForEach(optionalPacks.sorted(by: { $0.key < $1.key }), id: \.key) { tag, name in
                                Toggle(
                                    isOn: Binding(
                                        get: { selectedOptionalPackIDs.contains(tag) },
                                        set: { newValue in
                                            if newValue {
                                                selectedOptionalPackIDs.insert(tag)
                                            } else {
                                                selectedOptionalPackIDs.remove(tag)
                                            }
                                        }
                                    )
                                ) {
                                    Text(name)
                                    Text(tag)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .portalForm()
                    }

                    Form {
                        HStack {
                            VStack(alignment: .leading) {
                                Label("Installation Directory", systemImage: "folder")

                                Text(baseURL.prettyPath)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            if !FileManager.default.isWritableFile(atPath: baseURL.path) {
                                Image(systemName: "exclamationmark.triangle")
                                    .symbolVariant(.fill)
                                    .help("Folder is not writable.")
                            }

                            // TODO: unify
                            Button("Browse...") {
                                isInstallLocationFileImporterPresented = true
                            }
                            .fileImporter(
                                isPresented: $isInstallLocationFileImporterPresented,
                                allowedContentTypes: [.folder]
                            ) { result in
                                if case .success(let url) = result {
                                    baseURL = url
                                }
                            }
                        }

                        // FIXME: shared with EpicImport
                        Picker(
                            "Platform",
                            systemImage: "desktopcomputer.and.arrow.down",
                            selection: $platform
                        ) {
                            ForEach(supportedPlatforms ?? .init(), id: \.self) { platform in
                                Text(platform.description)
                            }
                        }
                        .task(priority: .userInitiated) {
                            isRetrievingSupportedPlatforms = true
                            defer { isRetrievingSupportedPlatforms = false }

                            // Falls back to every platform rather than to none. This reads the
                            // game's newest release entry out of Epic's cached metadata, and
                            // when that is missing or lists nothing recognisable the answer was
                            // an empty list — which left the picker blank and the selection on
                            // its default. Offering both and letting legendary refuse the wrong
                            // one is better than refusing to ask.
                            let retrieved = game.getSupportedPlatforms() ?? .init()
                            let platforms = (retrieved.isEmpty ? Set(Game.Platform.allCases) : retrieved)
                                .sorted(by: { $0 == .macOS && $1 != .macOS })

                            supportedPlatforms = platforms

                            // Set here, not in a callback on the modifier below. That callback
                            // is what was supposed to correct the selection, and when it did not
                            // run `platform` kept its default — so the size lookup asked about a
                            // build that does not exist and Install refused a platform the game
                            // never offered. Nothing downstream can be right until this is.
                            if !platforms.contains(platform), let first = platforms.first {
                                platform = first
                            }
                        }
                        .withOperationStatus(
                            operating: $isRetrievingSupportedPlatforms,
                            successful: .constant(nil),
                            observing: $supportedPlatforms,
                            action: { // update platform value so picker is never undefined
                                // sort to prioritise macOS first
                                let platforms = supportedPlatforms?.sorted(by: { $0 == .macOS && $1 != .macOS })
                                platform = platforms?.first ?? platform
                            }
                        )
                    }
                    .portalForm()
                }
            }

            HStack {
                Button("Cancel") {
                    isPresented = false
                }

                Spacer()

                // The lookup's own spinner. It used to ride on the Install button, which is
                // wrong for two reasons — pressing Install stopped it, and it made a size that
                // was still arriving look like a button that was busy — but moving the button
                // to its own flag left this with nothing drawing it at all.
                if fetchingOptionalPacks {
                    ProgressView()
                        .controlSize(.small)
                        .progressViewStyle(.circular)
                }

                // The size alone decides whether there is a size to show. It used to also
                // require `availableSpaceInBytes`, so a failed free-space query hid a download
                // size that had arrived perfectly well — blank again, for a reason that has
                // nothing to do with the game. How much room is left is the alert's business.
                else if let installSize = installSizeInBytes {
                    Text(ByteCountFormatter.string(fromByteCount: installSize, countStyle: .file))
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .onAppear {
                            if let availableSpace = availableSpaceInBytes,
                               let installSize = installSizeInBytes,
                               availableSpace < installSize {
                                isFreeSpaceAlertPresented = true
                            }
                        }
                        .alert("Insufficient disk space.",
                               isPresented: $isFreeSpaceAlertPresented) {
                            Button("OK", role: .cancel, action: {})
                        } message: {
                            // Names the volume. Without it this reads as a claim about the
                            // computer, and the number belongs to whichever disk the install
                            // directory is on — so somebody with plenty of room on another
                            // drive is told, apparently wrongly, that they have none.
                            Text("""
                                \(baseURL.path(percentEncoded: false)) has \(ByteCountFormatter.string(fromByteCount: availableSpaceInBytes ?? 0, countStyle: .file)) available.
                                \(game.description) requires \(ByteCountFormatter.string(fromByteCount: installSize, countStyle: .file)).
                                Choose another location with Browse, or free space on that disk.
                                (You may attempt to install anyway, but it will likely fail.)
                                """)
                        }
                } else if let probeFailure {
                    Text(probeFailure)
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }

                OperationButton(
                    "Install",
                    operating: $isStartingInstallation,
                    successful: .constant(nil),
                    placement: .leading
                ) {
                    Task { @MainActor [game] in
                        // Not `try?`. An installation that cannot even start — an unsupported
                        // platform, legendary refusing outright, the installed-data lock held
                        // by a download already running — used to close the sheet and leave
                        // nothing at all behind: no operation, no message, no log line. From
                        // the outside that is "it tries to install and then it stops".
                        do {
                            _ = try await EpicGamesGameManager.install(game: game,
                                                                       forPlatform: platform,
                                                                       qualityOfService: .default,
                                                                       optionalPackIDs: Array(selectedOptionalPackIDs),
                                                                       baseDirectoryURL: baseURL)
                            isPresented = false
                        } catch {
                            Logger.app.error("""
                                Couldn't start installing \(game.description, privacy: .public): \
                                \(error.localizedDescription)
                                """)
                            installationError = error
                        }
                    }
                }
                .disabled(supportedPlatforms == nil)
                // Not disabled while the size is being looked up. The size is advice, not a
                // precondition — and a lookup that fails or hangs was locking the person out of
                // installing the game at all.
                .disabled(!FileManager.default.isWritableFile(atPath: baseURL.path))
                .onAppear(perform: { spawnOptionalPacksFetchTask() })
                .onChange(of: game, { spawnOptionalPacksFetchTask() })
                .onChange(of: platform, { spawnOptionalPacksFetchTask() })
                // The platforms arriving is a trigger in its own right, and not a redundant
                // one: when the game's only platform is the one `platform` already holds,
                // resolving them changes nothing, `onChange(of: platform)` never fires, and
                // the probe — which now waits for the platforms before asking anything — would
                // never run at all.
                .onChange(of: supportedPlatforms, { spawnOptionalPacksFetchTask() })
                .buttonStyle(.portalProminent)
            }
            .padding(.top)
        }
        .alert("Couldn't start the installation.",
               isPresented: .init(get: { installationError != nil },
                                  set: { if !$0 { installationError = nil } }),
               presenting: installationError) { _ in
            Button("OK", role: .cancel, action: {})
        } message: { error in
            Text(error.localizedDescription)
        }
        .navigationTitle("Install \(game.description)")
    }
}

#Preview {
    EpicGamesGameInstallationView(
        game: .constant(placeholderGame(type: EpicGamesGame.self)),
        isPresented: .constant(true)
    )
    .padding()
}
