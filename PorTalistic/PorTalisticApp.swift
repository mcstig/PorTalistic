//
//  PorTalisticApp.swift
//  Mythic
//
//  Created by vapidinfinity (esi) on 9/9/2023.
//

// Copyright © 2023-2025 vapidinfinity

import SwiftUI
import Sparkle
import WhatsNewKit

@main
struct PorTalisticApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @AppStorage("isOnboardingPresented") var isOnboardingPresented: Bool = true

    @StateObject private var networkMonitor: NetworkMonitor = .shared

    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("PorTalistic", id: "main") {
            Group {
                if isOnboardingPresented {
                    OnboardingView()
                        .task(priority: .high) {
                            await MainActor.run {
                                NSApp.mainWindow?.isImmersive = true
                            }
                        }
                } else {
                    ContentView()
                        .whatsNewSheet()
                        .environmentObject(networkMonitor)
                        .task(priority: .high) {
                            await MainActor.run {
                                NSApp.mainWindow?.isImmersive = false
                            }
                        }
                }
            }
            .modifier(SparkleUpdater())
            // `Color.accentColor` follows the *system* accent, so sidebar selection and
            // every prominent control came out whatever colour the user had chosen in
            // System Settings — salmon, on the machine this was built on, next to a violet
            // app icon. Tinting the scene pins the app's own identity to its own controls.
            .tint(Theme.Palette.brand)
            .frame(minWidth: 850, minHeight: 400)
        }
        .handlesExternalEvents(matching: ["open"])
        .environment(
            \.whatsNew,
             WhatsNewEnvironment(
                versionStore:
                    {
#if DEBUG
                        InMemoryWhatsNewVersionStore()
#else
                        UserDefaultsWhatsNewVersionStore()
#endif
                    }(),
                whatsNewCollection: self
             )
        )
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button {
                    openWindow(id: "about")
                } label: {
                    Text("About PorTalistic")
                }
            }

            CommandGroup(after: .appInfo) {
                Button("Check for PorTalistic Updates...", action: { SparkleUpdateController.shared.checkForUpdates(userInitiated: true) })
                
                Button("Check for Mythic Engine Updates...") {
                    Task(priority: .userInitiated) {
                        await Engine.displayUpdateChecker(userInitiated: true)
                    }
                }

                Button("Restart Onboarding...") {
                    withAnimation {
                        isOnboardingPresented = true
                    }
                }
                .disabled(isOnboardingPresented)
            }
            
            CommandGroup(replacing: .help) {
                Link("Documentation", destination: Branding.readmeURL)
                Link("Discussions", destination: Branding.discussionsURL)
                Link("Report an Issue", destination: Branding.issuesURL)

                // Mythic's, and labelled as Mythic's. This used to be a "Support the
                // project" section holding upstream's Ko-Fi and a GitHub Sponsors page for
                // "PorTalisticApp", which does not exist — the rebrand's find-and-replace
                // went through a URL. Asking for money on behalf of a page that isn't there,
                // in an app people paid for, is the worst of both.
                Section("Upstream") {
                    Link("Mythic on GitHub", destination: Branding.upstreamRepositoryURL)
                    Link("Support Mythic's Author", destination: Branding.upstreamDonationURL)
                    Link("Mythic's Game Compatibility Sheet",
                         destination: URL(string: "https://docs.google.com/spreadsheets/d/1W_1UexC1VOcbP2CHhoZBR5-8koH-ZPxJBDWntwH-tsc/")!)
                }

                Section("More") {
                    Link("GitHub Repository", destination: Branding.repositoryURL)
                }
            }
        }

        Window("About PorTalistic", id: "about") {
            AboutView()
                // Every scene needs its own: `.tint` lives in the environment and each
                // window gets a fresh one. Without it the About window and the Settings
                // window drew their controls in the *system* accent — which is how the
                // Discord switch and the selected settings tab came out salmon in an
                // otherwise violet app.
                .tint(Theme.Palette.brand)
                .frame(width: 285, height: 400)
                .onAppear {
                    if let window = NSApp.window(withID: "about") {
                        window.isImmersive = true
                    }
                }
        }
        
        Settings {
            SettingsView()
                .tint(Theme.Palette.brand)
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(NetworkMonitor.shared)
}
