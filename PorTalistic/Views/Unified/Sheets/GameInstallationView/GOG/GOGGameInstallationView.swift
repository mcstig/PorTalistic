//
//  GOGGameInstallationView.swift
//  Mythic
//
//  Created by Claude (Cowork) on 13/9/2026.
//

// Copyright © 2023-2025 vapidinfinity

import Foundation
import SwiftUI
import OSLog

struct GOGGameInstallationView: View {
    @Binding var game: GOGGame
    @Binding var isPresented: Bool

    @AppStorage("installBaseURL") private var baseURL: URL = Bundle.appGames!

    @State private var isImageEmpty: Bool = true
    @State private var isInstallLocationFileImporterPresented: Bool = false

    @State private var platform: Game.Platform = .macOS
    @State private var supportedPlatforms: [Game.Platform]?

    /// What GOG says about this game for the chosen platform — the size, and the folder it
    /// wants to live in.
    ///
    /// Shown when it arrives, never waited on. Answering costs GOG a fetch and a decompress of
    /// every depot manifest the game and its DLC use, which for a large title is a minute or
    /// two; the install asks the same question again (and gets a cached answer if this got
    /// there first), so there is nothing to gain by making someone watch a spinner for it.
    @State private var metadata: GOGDL.Metadata?
    @State private var metadataError: Error?
    @State private var isFetchingMetadata: Bool = false

    @State private var isFreeSpaceAlertPresented: Bool = false
    @State private var installationError: Error?

    private var installSizeInBytes: Int64? {
        guard let metadata else { return nil }
        return metadata.size(inLanguage: language).disk
    }

    @State private var language: String = "en-US"

    private var availableSpaceInBytes: Int64? {
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: baseURL.path)
        return attributes?[.systemFreeSize] as? Int64
    }

    /// The probe currently asking gogdl about this game, and which generation of the question
    /// it is answering.
    @State private var metadataProbe: Task<Void, Never>?
    @State private var probeGeneration: Int = 0

    /// The Install button's own busy state, rather than the metadata lookup's. Sharing them
    /// meant pressing Install wrote the probe's flag and `OperationButton`'s `defer` cleared it
    /// again the moment the action returned, stopping a spinner that belonged to something
    /// else.
    @State private var isStartingInstallation: Bool = false

    /// Ask gogdl about this game, for the platform now selected.
    ///
    /// The same fault the Epic sheet had, in the same shape. This sheet opens with `platform`
    /// at a default, asks about that default straight away, and only afterwards works out which
    /// platforms the game actually offers — and the request made once the real platform was
    /// known used to be rejected by `guard !isFetchingMetadata` because the first one had not
    /// come back yet. The answer left on screen was about a build that does not exist.
    private func spawnMetadataFetchTask() {
        // Waits for the platforms to be known, not for the selection to be among them —
        // requiring that meant a game whose list came back empty was never asked about at all.
        guard supportedPlatforms != nil else { return }

        metadataProbe?.cancel()
        probeGeneration += 1
        let generation = probeGeneration

        let probe = Task(priority: .userInitiated) { [game, platform] in
            withAnimation { isFetchingMetadata = true }

            let fetchedLanguage = await GOGDL.installLanguage()

            do {
                let fetched = try await GOGDL.metadata(for: game, platform: platform)

                // A newer question has been asked; its answer is the one that belongs here.
                guard generation == probeGeneration else { return }

                language = fetchedLanguage
                metadata = fetched
                metadataError = nil
            } catch {
                guard generation == probeGeneration else { return }

                language = fetchedLanguage
                metadata = nil
                metadataError = error
            }

            withAnimation { isFetchingMetadata = false }
        }
        metadataProbe = probe

        // No watchdog. The same thirty-second one was added here and it was wrong for the same
        // reason: these lookups renew a storefront login before they answer, and being slow is
        // not being stuck. Bounding them belongs to the process that runs them.
    }

    var body: some View {
        VStack {
            GameSheetHeader(game: game,
                            action: String(localized: "Install"),
                            // The download size used to be tertiary text beside the Install
                            // button, where it read as a caption on the button rather than
                            // as a fact about the game.
                            badges: downloadSizeBadge.map { [$0] } ?? []) {
                VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                    Form {
                        HStack {
                            VStack(alignment: .leading) {
                                Label("Installation Directory", systemImage: "folder")

                                Text(destinationDescription)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            if !FileManager.default.isWritableFile(atPath: baseURL.path) {
                                Image(systemName: "exclamationmark.triangle")
                                    .symbolVariant(.fill)
                                    .help("Folder is not writable.")
                            }

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
                            // Sorted so a native build wins where GOG ships one, and falling
                            // back to every platform rather than to none: an undetectable list
                            // left the picker empty and the game un-installable, where offering
                            // both and letting gogdl refuse the wrong one costs nothing.
                            let retrieved = game.getSupportedPlatforms() ?? .init()
                            let platforms = (retrieved.isEmpty ? Set(Game.Platform.allCases) : retrieved)
                                .sorted(by: { $0 == .macOS && $1 != .macOS })

                            supportedPlatforms = platforms

                            if !platforms.contains(self.platform), let first = platforms.first {
                                self.platform = first
                            }
                        }

                        LabeledContent {
                            Text(language)
                                .foregroundStyle(.secondary)
                        } label: {
                            Label("Language", systemImage: "character.bubble")
                        }
                    }
                    .portalForm()

                    // Only the error. The "asking GOG how big this download is…" line that
                    // used to sit here said in a sentence what a spinner beside the Install
                    // button says without one — which is how Epic's sheet already did it.
                    if let metadataError {
                        Text(metadataError.localizedDescription)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }
                }
            }

            HStack {
                Button("Cancel", role: .cancel) {
                    isPresented = false
                }

                Spacer()

                // The lookup's own spinner, for the same reason as Epic's: it used to ride on
                // the Install button, and moving that button to its own flag left nothing
                // drawing it.
                if isFetchingMetadata {
                    ProgressView()
                        .controlSize(.small)
                        .progressViewStyle(.circular)
                }

                if let availableSpace = availableSpaceInBytes,
                   let installSize = installSizeInBytes {
                    // Nothing to draw — the size is a badge in the header now. This only
                    // still exists to notice, once the size arrives, that it won't fit.
                    Color.clear
                        .frame(width: 0, height: 0)
                        .onAppear {
                            if availableSpace < installSize {
                                isFreeSpaceAlertPresented = true
                            }
                        }
                        .alert("Insufficient disk space.",
                               isPresented: $isFreeSpaceAlertPresented) {
                            Button("OK", role: .cancel, action: {})
                        } message: {
                            Text("""
                                You have \(ByteCountFormatter.string(fromByteCount: availableSpace, countStyle: .file)) available.
                                However, \(game.description) requires \(ByteCountFormatter.string(fromByteCount: installSize, countStyle: .file)).
                                Please free disk space and try again.
                                (You may attempt to install the game anyway, but it will likely fail.)
                                """)
                        }
                }

                // The same control Epic's sheet uses. The spinner here is this button's own:
                // it used to ride on `isFetchingMetadata`, which belongs to the size lookup —
                // and the comment that used to sit here claimed the button was disabled until
                // that landed, which it never was.
                OperationButton(
                    "Install",
                    operating: $isStartingInstallation,
                    successful: .constant(nil),
                    placement: .leading
                ) {
                    Task { @MainActor [game, platform, baseURL] in
                        do {
                            _ = try await GOGGameManager.install(game: game,
                                                                 platform: platform,
                                                                 qualityOfService: .default,
                                                                 baseDirectoryURL: baseURL)
                            isPresented = false
                        } catch {
                            installationError = error
                        }
                    }
                }
                .disabled(supportedPlatforms == nil)
                .disabled(!FileManager.default.isWritableFile(atPath: baseURL.path))
                .onAppear(perform: { spawnMetadataFetchTask() })
                .onChange(of: game, { spawnMetadataFetchTask() })
                .onChange(of: platform, { spawnMetadataFetchTask() })
                // Not redundant: when the game's only platform is the one `platform` already
                // holds, resolving the list changes nothing and the probe would never run.
                .onChange(of: supportedPlatforms, { spawnMetadataFetchTask() })
                .buttonStyle(.portalProminent)
            }
            .padding(.top)
        }
        .navigationTitle("Install \(game.description)")
        .alert("Couldn't start the download.",
               isPresented: .init(get: { installationError != nil },
                                  set: { if !$0 { installationError = nil } }),
               presenting: installationError) { _ in
            Button("OK", role: .cancel, action: {})
        } message: { error in
            Text(error.localizedDescription)
        }
    }

    /// The download size, once GOG has told us, as a fact about the game.
    private var downloadSizeBadge: PortalBadge? {
        guard let installSize = installSizeInBytes else { return nil }
        return .init(ByteCountFormatter.string(fromByteCount: installSize, countStyle: .file),
                     systemImage: "arrow.down.circle",
                     tint: Theme.Palette.brandSecondary)
    }

    /// Shows where the game will actually land once GOG has named the folder, and the base
    /// directory until then — rather than inventing a folder name that would turn out wrong.
    private var destinationDescription: String {
        guard let folderName = metadata?.folderName else { return baseURL.prettyPath }
        return baseURL.appending(path: folderName).prettyPath
    }
}

#Preview {
    GOGGameInstallationView(
        game: .constant(placeholderGame(type: GOGGame.self)),
        isPresented: .constant(true)
    )
    .padding()
}
