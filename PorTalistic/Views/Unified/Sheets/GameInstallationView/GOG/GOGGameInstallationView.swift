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

    private func spawnMetadataFetchTask() {
        guard !isFetchingMetadata else { return }

        Task(priority: .userInitiated) { [game, platform] in
            withAnimation { isFetchingMetadata = true }
            defer { withAnimation { isFetchingMetadata = false } }

            language = await GOGDL.installLanguage()

            do {
                metadata = try await GOGDL.metadata(for: game, platform: platform)
                metadataError = nil
            } catch {
                metadata = nil
                metadataError = error
            }
        }
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
                            // Sorted so a native build wins where GOG ships one.
                            let platforms = game.getSupportedPlatforms()?
                                .sorted(by: { $0 == .macOS && $1 != .macOS })
                            supportedPlatforms = platforms
                            self.platform = platforms?.first ?? self.platform
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

                // The same control Epic's sheet uses: the spinner rides beside the label
                // while the size lookup is in flight, and the button is disabled until it
                // lands.
                OperationButton(
                    "Install",
                    operating: $isFetchingMetadata,
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
                .onChange(of: platform, { spawnMetadataFetchTask() })
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
