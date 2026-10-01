//
//  SparkleUpdaterPreviewView.swift
//  Mythic
//
//  Created by Josh on 10/23/24.
//

// Copyright © 2023-2025 vapidinfinity

import SwiftUI
import Sparkle
import MarkdownUI
import ColorfulX

extension SparkleUpdater {
    struct PreviewView: View {
        let appcast: SUAppcastItem
        let choice: (SparkleUpdateController.UpdateChoice) -> Void

        @State private var colorfulViewColors: [Color] = [
            .init(hex: "#7541FF"),
            .init(hex: "#5412FF"),
            Color(nsColor: .windowBackgroundColor)
        ]
        @State private var colorfulAnimationSpeed: Double = 1
        @State private var colorfulAnimationNoise: Double = 0

        /// The sheet's size, fixed.
        ///
        /// It used to be `.fixedSize()` — its ideal size, which for text is the width of its
        /// longest line. So the sheet was as wide as the longest release note, the first note of
        /// any length made it wider than the screen, and the version sentence on the left, laid
        /// out at *its* ideal width in a column narrower than that, was clipped at both ends.
        /// Inside a fixed frame, everything wraps.
        static let size: CGSize = .init(width: 720, height: 420)
        static let sidebarWidth: CGFloat = 230

        var body: some View {
            HStack(spacing: 0) {
                VStack(alignment: .center, spacing: 16) {
                    VStack(spacing: 8) {
                        BundleIconView()
                            .shadow(radius: .leastNormalMagnitude)
                            .frame(width: 96, height: 96)

                        VStack(spacing: 2) {
                            Text(Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "Unknown")
                                .font(.title2)
                                .bold()

                            Text("v\(appcast.displayVersionString.isEmpty ? "0.0.0" : appcast.displayVersionString) (\(appcast.versionString.isEmpty ? "0" : appcast.versionString))")
                                .font(.caption)
                                .opacity(0.6)
                        }
                    }

                    Text("You have \(appVersionDescription). PorTalistic restarts to finish updating.")
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .opacity(0.6)

                    Spacer(minLength: 0)

                    VStack(spacing: 4) {
                        Button {
                            choice(.update)
                        } label: {
                            Text("Update and Restart")
                                .padding(.vertical)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.portalProminent)
                        .clipShape(.capsule)
                        
                        if !appcast.isCriticalUpdate {
                            // Asked again at the next launch, and meanwhile from the sidebar.
                            Button {
                                choice(.dismiss)
                            } label: {
                                Text("Later")
                                    .padding(.vertical)
                                    .multilineTextAlignment(.center)
                                    .frame(maxWidth: .infinity)
                            }
                            .clipShape(.capsule)
                        }
                    }
                }
                .padding()
                .frame(width: Self.sidebarWidth)
                .frame(maxHeight: .infinity)
                .background(
                    ColorfulView(color: $colorfulViewColors,
                                 speed: $colorfulAnimationSpeed,
                                 noise: $colorfulAnimationNoise)
                )
                .foregroundStyle(.white)

                if let itemDescription = appcast.itemDescription, !itemDescription.isEmpty {
                    ScrollView {
                        Markdown {
                            itemDescription
                        }
                        .multilineTextAlignment(.leading)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView(
                        "No Release Notes Found.",
                        systemImage: "pc"
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: Self.size.width, height: Self.size.height)
        }
    }
}

#Preview {
    SparkleUpdater.PreviewView(appcast: .empty(), choice: { _ in })
}
