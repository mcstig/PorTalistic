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

        var body: some View {
            HStack(spacing: 0) {
                VStack(alignment: .center) {
                    VStack {
                        VStack {
                            BundleIconView()
                                .shadow(radius: .leastNormalMagnitude)
                                .aspectRatio(contentMode: .fit)
                            
                            VStack {
                                Text(Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "Unknown")
                                    .font(.title2)
                                    .bold()
                                
                                Text("v\(appcast.displayVersionString.isEmpty ? "0.0.0" : appcast.displayVersionString) (\(appcast.versionString.isEmpty ? "0" : appcast.versionString))")
                                    .font(.caption)
                                    .opacity(0.6)
                            }
                        }
                        
                        Text("You have \(appVersion?.description ?? "an older version"). PorTalistic restarts to finish updating.")
                            .font(.callout)
                            .multilineTextAlignment(.center)
                            .opacity(0.6)
                    }

                    VStack {
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
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView(
                        "No Release Notes Found.",
                        systemImage: "pc"
                    )
                }
            }
            .fixedSize()
        }
    }
}

#Preview {
    SparkleUpdater.PreviewView(appcast: .empty(), choice: { _ in })
}
