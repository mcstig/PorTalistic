//
//  GameCard+ImageCard+.swift
//  Mythic
//
//  Created by vapidinfinity (esi) on 8/11/2025.
//

// Copyright © 2023-2025 vapidinfinity

import Foundation
import SwiftUI
import OSLog
import Shimmer

extension GameCard {
    struct ImageURLModifierView: View {
        @Binding var game: Game
        @Binding var imageURL: URL?

        @State private var isThumbnailFileImporterPresented: Bool = false
        @State private var isThumbnailImportErrorPresented: Bool = false
        @State private var thumbnailImportError: Error?

        var body: some View {
            // The field, then its controls, then its note — each on its own line.
            //
            // All of this used to be passed to `TextField` as *label* content: two `Text`s,
            // an `HStack` with a sentence and a button, and another button. macOS puts a
            // field's label in a narrow column beside it, so in the import sheet that column
            // was seventy points wide and "Otherwise, browse for a thumbnail file:" rendered
            // as four wrapped lines with a button embedded in the middle of them.
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                Text("Thumbnail")
                    .font(.system(.subheadline, weight: .semibold))

                TextField("Paste an image URL", text: .init(
                    get: { imageURL?.path ?? .init() },
                    set: { imageURL = .init(string: $0) }
                ))
                .textFieldStyle(.roundedBorder)
                .truncationMode(.tail)
                .onChange(of: imageURL) {
                    game._verticalImageURL = $1
                }

                HStack(spacing: Theme.Spacing.small) {
                        Button("Browse...") {
                            isThumbnailFileImporterPresented = true
                        }
                        .fileImporter(
                            isPresented: $isThumbnailFileImporterPresented,
                            allowedContentTypes: [.png, .jpeg, .gif, .bmp, .ico, .tiff, .heic, .webP]
                        ) { result in
                            switch result {
                            case .success(let url):
                                guard url.startAccessingSecurityScopedResource() else { return }
                                defer { url.stopAccessingSecurityScopedResource() }

                                guard let appHome = Bundle.appHome else { return }

                                do {
                                    guard let storefront = game.storefront else { throw CocoaError(.coderInvalidValue) }
                                    let thumbnailDirectoryURL: URL = appHome.appending(path: "Thumbnails/Custom/\(storefront.description)")

                                    if !FileManager.default.fileExists(atPath: thumbnailDirectoryURL.path(percentEncoded: false)) {
                                        try FileManager.default.createDirectory(at: thumbnailDirectoryURL, withIntermediateDirectories: true)
                                    }

                                    let newThumbnailURL = thumbnailDirectoryURL.appendingPathComponent(UUID().uuidString)

                                    try FileManager.default.copyItem(at: url, to: newThumbnailURL)

                                    imageURL = newThumbnailURL
                                } catch {
                                    Logger.app.error("Unable to import thumbnail: \(error.localizedDescription)")
                                    presentThumbnailImportError(error)
                                }
                            case .failure(let failure):
                                presentThumbnailImportError(failure)
                            }

                            @MainActor
                            func presentThumbnailImportError(_ error: Error) {
                                thumbnailImportError = error
                                isThumbnailImportErrorPresented = true
                            }
                        }
                        .alert(isPresented: $isThumbnailImportErrorPresented) {
                            Alert(
                                title: .init("Unable to import thumbnail."),
                                message: .init(thumbnailImportError?.localizedDescription ?? "Unknown Error."),
                                dismissButton: .default(Text("OK"))
                            )
                        }


                    Button("Reset", role: .destructive) {
                        imageURL = nil
                    }
                    .disabled(imageURL == nil)

                    Spacer(minLength: 0)
                }

                Text("Optional. A 3:4 image works best; without one, a colour is derived from the game's name.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
