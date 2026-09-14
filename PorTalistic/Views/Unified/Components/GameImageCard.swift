//
//  GameImageCard.swift
//  Mythic
//
//  Created by vapidinfinity (esi) on 1/12/2025.
//

// Copyright © 2023-2025 vapidinfinity

import Foundation
import SwiftUI
import Shimmer

struct GameImageCard: View {
    var game: Game?
    var url: URL?
    @Binding var isImageEmpty: Bool
    
    var withBlur: Bool
    @AppStorage("gameImageCardBlur") private var imageCardBlur: Double = 0.0

    /// Changing this gives `AsyncImage` a new identity, which is the only way to make it try
    /// again: it loads once per identity and keeps a failure forever. One dropped request
    /// otherwise leaves a card reading "Unable to load the image." for the rest of the
    /// session, which is how a whole library can look broken because the network blinked.
    @State private var attempt: Int = 0
    @State private var isRetrying: Bool = false
    
    /// - Note: `game` must be passed as a parameter in order to include fallback image URLs.
    init(game: Game? = nil, url: URL?, isImageEmpty: Binding<Bool>, withBlur: Bool = true) {
        self.game = game
        self.url = url
        self._isImageEmpty = isImageEmpty
        self.withBlur = withBlur
    }
    
    var body: some View {
        GeometryReader { geometry in
            if let url = url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        Rectangle()
                            .onAppear {
                                withAnimation { isImageEmpty = true }
                            }
                            .foregroundStyle(.quinary)
                            .shimmering(
                                animation: .easeInOut(duration: 1)
                                    .repeatForever(autoreverses: false),
                                bandSize: 1
                            )
                    case .success(let image):
                        ZStack {
                            // blurred image as background
                            // save resources by only create this image if it'll be used for blur
                            if withBlur && (imageCardBlur > 0) {
                                // save resources by decreasing resolution scale of blurred image
                                let renderer: ImageRenderer = {
                                    let renderer = ImageRenderer(content: image)
                                    renderer.scale = 0.2
                                    return renderer
                                }()
                                
                                if let image = renderer.cgImage {
                                    Image(image, scale: 1, label: .init(""))
                                        .resizable()
                                        .blur(radius: imageCardBlur)
                                }
                            }
                            
                            image
                                .resizable()
                                .modifier(FadeInModifier())
                                .onAppear {
                                    withAnimation { isImageEmpty = false }
                                }
                        }
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geometry.size.width,
                               height: geometry.size.height)
                    case .failure(let error):
                        ContentUnavailableView {
                            Label("Unable to load the image.", systemImage: "photo.badge.exclamationmark")
                        } description: {
                            Text(error.localizedDescription)
                        } actions: {
                            Button("Try Again") { attempt += 1 }
                                .disabled(isRetrying)
                        }
                        .onAppear {
                            withAnimation { isImageEmpty = true }
                            scheduleRetry()
                        }
                    @unknown default:
                        ContentUnavailableView(
                            "Unable to load the image.",
                            systemImage: "photo.badge.exclamationmark",
                            description: .init("Please check your internet connection, and try again.")
                        )
                        .onAppear {
                            withAnimation { isImageEmpty = true }
                        }
                    }
                }
                .id(attempt)
                .frame(width: geometry.size.width,
                       height: geometry.size.height)
            } else if let game, game.isFallbackImageAvailable {
                GameImageCard.FallbackGameImageCard(game: .constant(game), withBlur: withBlur)
                    .padding()
                    .frame(width: geometry.size.width,
                           height: geometry.size.height)
            } else {
                ContentUnavailableView(
                    "Image Unavailable",
                    systemImage: "photo.badge.exclamationmark",
                    description: .init("""
                    This game doesn't have an image that Mythic can display in this style.
                    """)
                )
                .frame(width: geometry.size.width,
                       height: geometry.size.height)
            }
        }
        .background(.quinary)
        .clipShape(.rect(cornerRadius: 20))
    }

    /// Retries a failure a couple of times, spaced out, before leaving it to the button.
    ///
    /// Bounded rather than indefinite: a URL that 404s will 404 forever, and a grid of cards
    /// quietly retrying one of those in a loop is worse than a card that says it failed.
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

extension GameImageCard {
    // TODO: implement for windows .exes by implementing PEFile
    struct FallbackGameImageCard: View {
        @Binding var game: Game
        @AppStorage("gameImageCardBlur") private var imageCardBlur: Double = 0.0
        var withBlur: Bool = true
        
        var body: some View {
            if case .installed(let location, _) = game.installationState {
                
                let image = Image(nsImage: NSWorkspace.shared.icon(forFile: location.path))
                
                ZStack {
                    // blurred image as background
                    // save resources by only create this image if it'll be used for blur
                    if withBlur && (imageCardBlur > 0) {
                        // save resources by decreasing resolution scale of blurred image
                        let renderer: ImageRenderer = {
                            let renderer = ImageRenderer(content: image)
                            renderer.scale = 0.2
                            return renderer
                        }()
                        
                        if let image = renderer.cgImage {
                            Image(image, scale: 1, label: .init(""))
                                .resizable()
                                .clipShape(.rect(cornerRadius: 20))
                                .blur(radius: imageCardBlur)
                        }
                    }
                    
                    image
                        .resizable()
                        .scaledToFit()
                        .modifier(FadeInModifier())
                }
            } else {
                RoundedRectangle(cornerRadius: 20)
                    .fill(.windowBackground)
                    .shimmering(
                        animation: .easeInOut(duration: 1)
                            .repeatForever(autoreverses: false),
                        bandSize: 1
                    )
            }
        }
    }
}

#Preview {
    HStack {
        GameImageCard(game: placeholderGame(type: LocalGame.self) as Game,
                      url: placeholderGame(type: LocalGame.self).horizontalImageURL,
                      isImageEmpty: .constant(false),
                      withBlur: true)
        .aspectRatio(16/9, contentMode: .fill)
        
        GameImageCard(game: placeholderGame(type: Game.self),
                      url: placeholderGame(type: Game.self).verticalImageURL,
                      isImageEmpty: .constant(false),
                      withBlur: true)
        .aspectRatio(3/4, contentMode: .fill)
    }
    .aspectRatio(contentMode: .fit)
    .padding()
}
