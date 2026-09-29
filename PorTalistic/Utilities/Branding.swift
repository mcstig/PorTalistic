//
//  Branding.swift
//  Mythic
//
//  Created by Claude Opus 5 on 14/9/2026.
//

// Copyright © 2023-2025 vapidinfinity
// Copyright © 2026 Michael Stoian

import Foundation

/**
 Who this application is, in one place.

 Collected here because a fork's name and its endpoints are the same kind of fact and were
 previously neither collected nor consistent: the brand appeared as a string literal in six
 views, and three of the URLs pointed at infrastructure belonging to the project this was
 forked from. Two of those would have been actively harmful in a release build, which is the
 real argument for a single place — a scattered endpoint is an endpoint nobody audits.

 - Note: This deliberately does *not* rename the engine. "Mythic Engine" is upstream's name
   for their Game Porting Toolkit derived build, this project uses that build, and calling it
   anything else would take credit for someone else's work. The same goes for the copyright
   headers throughout: GPLv3 requires the original notices be kept, so this fork adds its own
   beside them rather than replacing them.
 */
enum Branding {
    /// What the application calls itself. Matches `CFBundleDisplayName`, and read from it so
    /// the two cannot drift.
    static var name: String {
        Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String ?? "PorTalistic"
    }

    /// The project's public home, and the answer to every support question for now.
    ///
    /// The repository rather than a website because the repository exists. Pointing these at
    /// a domain that hasn't been registered would be worse than pointing them somewhere
    /// plain: a dead link in a paid app reads as abandonment.
    static let repositoryURL: URL = .init(string: "https://github.com/mcstig/PorTalistic")!

    static var issuesURL: URL { repositoryURL.appending(path: "issues") }

    /// Where people support this project.
    ///
    /// PorTalistic is free — no paywall, no gated features — and this is how it keeps going.
    /// Defined once because it appears in the sidebar, the Help menu and What's New, and a link
    /// written out three times is a link that ends up pointing somewhere different in one of
    /// them. Upstream's Ko-fi stays below under upstream's own name; it is not this.
    static let patreonURL: URL = .init(string: "https://www.patreon.com/PorTalistic")!

    /// Where this fork came from.
    ///
    /// Linked in the Help menu, under upstream's own name rather than this one. GPLv3 asks
    /// for the notices to be kept; presenting Mythic's author's donation links as "support
    /// the project" under this app's name would keep the letter of that and none of the
    /// point.
    static let upstreamRepositoryURL: URL = .init(string: "https://github.com/MythicApp/Mythic")!
    static let upstreamDonationURL: URL = .init(string: "https://ko-fi.com/vapidinfinity")!
    static var discussionsURL: URL { repositoryURL.appending(path: "discussions") }
    static var readmeURL: URL { repositoryURL }

    /// Where Sparkle looks for updates: `appcast.xml` in this project's own repository,
    /// written by `Scripts/release.sh` and served the same way as the compatibility manifest.
    ///
    /// `SUFeedURL` used to point at upstream's appcast, which would have quietly updated every
    /// user of this fork *to upstream Mythic* — replacing the application they installed with a
    /// different one. That is the most damaging single line a fork can carry, so the feed is
    /// named twice — here, as the switch the updater checks, and as `SUFeedURL` in Info.plist,
    /// which is what Sparkle reads — and `Scripts/check-invariants.sh` holds both to this
    /// repository. `nil` turns updates off.
    static let appcastURL: URL? = .init(string: "https://raw.githubusercontent.com/mcstig/PorTalistic/main/appcast.xml")

    /// Whether the bundled Firebase configuration belongs to this application.
    ///
    /// Upstream's `GoogleService-Info.plist` is still in the repository and names upstream's
    /// project and upstream's bundle identifier. Configuring Firebase against it would send
    /// this fork's crash reports and analytics into someone else's project — a privacy problem
    /// for users, and not this project's data to collect. Comparing the plist's `BUNDLE_ID`
    /// with our own is enough to tell, and means Firebase switches itself back on the day a
    /// plist for this app replaces it.
    static var hasOwnFirebaseConfiguration: Bool {
        guard let url = Bundle.main.url(forResource: "GoogleService-Info", withExtension: "plist"),
              let plist = NSDictionary(contentsOf: url),
              let configured = plist["BUNDLE_ID"] as? String,
              let ours = Bundle.main.bundleIdentifier else {
            return false
        }

        return configured == ours
    }
}
