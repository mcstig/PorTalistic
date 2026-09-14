//
//  AboutView.swift
//  Mythic
//
//  Created by vapidinfinity (esi) on 25/4/2025.
//

// Copyright © 2023-2025 vapidinfinity

import Foundation
import SwiftUI
import SemanticVersion
import ColorfulX

struct AboutView: View {
    @State private var colorfulAnimationColors: [Color] = [
        .init(hex: "#5412F6"),
        .init(hex: "#7E1ED8"),
        .init(hex: "#2C2C2C")
    ]
    @State private var colorfulAnimationSpeed: Double = 1
    @State private var colorfulAnimationNoise: Double = 0
    
    @State private var showGradientView: Bool = false
    @State private var animateTextView: Bool = false
    @State private var isChevronHovered: Bool = false

    @State private var engineVersion: SemanticVersion?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack {
                    VStack(alignment: .center) {
                        BundleIconView()
                            .frame(width: 100, height: 100)
                        
                        if !animateTextView {
                            Group {
                                Text(Branding.name)
                                    .font(.largeTitle)
                                Text("by Michael Stoian")
                                Text("a fork of Mythic by vapidinfinity ✦")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                
                                Divider()
                                    .frame(width: 100)
                                
                                VStack {
                                    if let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                                       let bundleVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
                                       let version: SemanticVersion = .init("\(shortVersion)+\(bundleVersion)") {
                                        Text(version.prettyString)
                                    }
                                    
                                    if let engineVersion {
                                        Text("Engine \(engineVersion.prettyString)")
                                    }
                                }
                                .task { @MainActor in
                                    engineVersion = await Engine.installedVersion
                                }
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            }
                            .blur(radius: showGradientView ? 30 : 0)
                        }
                    }
                    .id(1)
                    .frame(height: 400)
                    .overlay(alignment: .bottom) {
                        Button {
                            withAnimation(.easeInOut) {
                                proxy.scrollTo(2)
                            }
                            
                        } label: {
                            VStack {
                                if isChevronHovered {
                                    Text("scroll... or just jump down!")
                                        .frame(width: 500)
                                }
                                
                                Image(systemName: "chevron.down")
                            }
                        }
                        .buttonStyle(.plain)
                        .symbolEffect(.pulse)
                        .onHover { hovered in
                            withAnimation(.easeInOut(duration: 0.4)) {
                                isChevronHovered = hovered
                            }
                        }
                        .padding()
                    }
                    
                    Divider()
                        .padding(.horizontal)
                    
                    Text(#""An open-source macOS game launcher that runs Windows games through Wine, choosing the runtime and graphics translation each game needs — across multiple storefronts.""#)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .padding()
                    
                    Divider()
                        .padding(.horizontal)
                    
                    VStack(alignment: .center, spacing: 10) {
                        Text("Acknowledgements")
                            .font(.title)
                        
                        AcknowledgementCard(
                            URL: .init(string: "https://github.com/MythicApp/Mythic")!,
                            image: Image("BlankAppIcon"),
                            title: "✦ Mythic, by vapidinfinity",
                            description: "The launcher this one is forked from, under the GPLv3. Most of what works here was working there first."
                        )

                        AcknowledgementCard(
                            URL: .init(string: "https://codeweavers.com/")!,
                            image: Image("CrossOver"),
                            title: "⭐ CodeWeavers, and Gcenx",
                            description: "Developing, maintaining, and porting Wine, the technology behind this application's Windows® → macOS API translation layer."
                        )
                        
                        AcknowledgementCard(
                            URL: .init(string: "https://getwhisky.app/")!,
                            image: Image("Whisky"),
                            title: "🕊️ Whisky",
                            description: "Providing Mythic Engine's foundation."
                        )
                        
                        AcknowledgementCard(
                            URL: Branding.repositoryURL,
                            image: Image("BlankAppIcon"),
                            title: "⭐ Others",
                            description: "View this application's other dependencies."
                        )
                    }
                    .id(2)
                    .padding()
                    .frame(height: 400)
                }
            }
            .background(showGradientView ? nil : WindowBlurView().ignoresSafeArea())
            .background(showGradientView ? ColorfulView(color: $colorfulAnimationColors, speed: $colorfulAnimationSpeed, noise: $colorfulAnimationNoise).ignoresSafeArea() : nil)
            .frame(width: 285, height: 400)
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 1)) {
                    showGradientView = hovering
                }
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    withAnimation(.easeInOut(duration: 0.7)) {
                        animateTextView = hovering
                    }
                }
            }
            .fixedSize()
        }
    }
}

extension AboutView {
    struct AcknowledgementCard: View {
        var URL: URL
        var image: Image
        var title: String
        var description: String
        
        @State private var isChevronHovering: Bool = false
        
        var body: some View {
            Button {
                NSWorkspace.shared.open(URL)
            } label: {
                HStack(alignment: .center) {
                    image
                        .resizable()
                        .frame(width: 48, height: 48)
                        .aspectRatio(contentMode: .fit)
                    
                    VStack(alignment: .leading) {
                        Text(title)
                            .font(.headline)
                        
                        Text(description)
                            .tint(.secondary)
                    }
                    
                    Spacer()
                    
                    Image(systemName: "chevron.right")
                        .onHover {
                            isChevronHovering = $0
                        }
                }
            }
            .buttonStyle(.plain)
            .padding(.bottom)
        }
    }
}

#Preview {
    AboutView()
}
