//
//  SteamClientPin.swift
//  Mythic
//
//  Created by Claude (Cowork) on 7/9/2026.
//

// Copyright © 2023-2025 vapidinfinity

import Foundation
import OSLog

/**
 A Steam client build, pinned to the date its packages were archived.

 The current Steam client's interface is Chromium 126 driving ANGLE, composited by Steam's
 own window system. Under Wine it gets far enough to be maddening — it installs, connects to
 Valve, runs the login page's JavaScript — and then draws nothing, and Steam's watchdog
 closes it about a minute later. Every launch argument that looks like it should help
 (`-cef-disable-gpu`, `-cef-force-32bit`, `-noreactlogin`) either does nothing or makes it
 worse, because the fault isn't in anything an argument reaches.

 What does work, and what the Wine and CrossOver communities settled on, is running an older
 client. Steam's bootstrapper will fetch its packages from wherever `-overridepackageurl`
 points, so pointing it at an Internet Archive snapshot of `media.steampowered.com/client`
 installs the client as it was on that date. ``Steam/setBootstrapperUpdateInhibited(_:containerURL:)``
 then stops it updating back.

 - Important: Valve moves its backend along with the client, so a pinned build eventually
   loses the ability to sign in. This is a way to make Steam usable now, not forever, and
   ``Steam`` treats it as a repairable state rather than a permanent one.
 */
struct SteamClientPin: Identifiable, Hashable {
    /// Stable identifier, used to record which pin a container is on.
    let id: String

    /// How to describe this build to someone choosing between them.
    let name: String

    /// Internet Archive timestamp, `YYYYMMDDhhmmss`.
    let archiveTimestamp: String

    /// Why this particular build.
    let summary: String

    /// Where Steam's bootstrapper should fetch its packages from.
    ///
    /// The `if_` suffix asks the Wayback Machine for the archived bytes rather than its own
    /// framed viewer, which matters because the bootstrapper is parsing manifests, not
    /// looking at a web page.
    var packageURL: URL {
        .init(string: "https://web.archive.org/web/\(archiveTimestamp)if_/media.steampowered.com/client/")!
    }
}

extension SteamClientPin {
    private static let log: Logger = .custom(category: "SteamClientPin")

    /// The manifest Steam's bootstrapper reads to decide what to install.
    ///
    /// Its captures are the only thing that makes a downgrade possible: whatever this file
    /// said on a given date is the client you get back.
    private static let manifestPath = "media.steampowered.com/client/steam_client_win64"

    /// Fallback offered when the Internet Archive can't be reached.
    ///
    /// Deliberately vague about which build it lands on, because that's the truth — the
    /// archive serves the nearest capture it has, which may not be the date asked for.
    static let fallback: SteamClientPin = .init(
        id: "20240520000000",
        name: "Older client",
        archiveTimestamp: "20240520000000",
        summary: "Whatever build the Internet Archive has nearest to May 2024."
    )

    /// Asks the Internet Archive which captures of Steam's client manifest actually exist.
    ///
    /// Hardcoding dates does not work. A timestamp with no capture behind it silently
    /// resolves to the nearest one the archive does have — asking for May 2024 here returned
    /// a November 2025 build, which is far too recent to avoid the interface problem it was
    /// meant to sidestep. The archive knows what it holds; ask it.
    ///
    /// `collapse=digest` gives one entry per *distinct* manifest rather than one per capture,
    /// so the list is actual client builds instead of hundreds of identical crawls.
    static func availableSnapshots() async throws -> [SteamClientPin] {
        var components = URLComponents(string: "https://web.archive.org/cdx/search/cdx")!
        components.queryItems = [
            .init(name: "url", value: manifestPath),
            .init(name: "output", value: "json"),
            .init(name: "filter", value: "statuscode:200"),

            // One capture per month, across years. Not `limit=-25`: a negative limit asks
            // for the *newest* captures, so the list only ever contained builds from the
            // last few months — which are precisely the ones that don't render. Anything
            // old enough to be worth trying was never offered.
            .init(name: "collapse", value: "timestamp:6"),
            .init(name: "from", value: "2022"),
            .init(name: "to", value: latestUsefulTimestamp)
        ]

        let (data, _) = try await URLSession.shared.data(from: components.url!)

        // CDX JSON is an array of arrays whose first row is the column names.
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String]],
              let header = rows.first,
              let timestampColumn = header.firstIndex(of: "timestamp") else {
            log.warning("The Internet Archive's capture index wasn't in the shape we expected.")
            return [fallback]
        }

        let formatter: DateFormatter = .init()
        formatter.dateFormat = "yyyyMMddHHmmss"
        formatter.timeZone = .init(secondsFromGMT: 0)

        let display: DateFormatter = .init()
        display.dateStyle = .medium
        display.timeStyle = .none

        let pins: [SteamClientPin] = rows.dropFirst().compactMap { row in
            guard row.indices.contains(timestampColumn) else { return nil }
            let timestamp = row[timestampColumn]
            guard let date = formatter.date(from: timestamp) else { return nil }

            return .init(
                id: timestamp,
                name: display.string(from: date),
                archiveTimestamp: timestamp,
                summary: String(localized: "The Steam client as it stood on \(display.string(from: date)).")
            )
        }

        let usable = pins.sorted { $0.archiveTimestamp > $1.archiveTimestamp }
        return usable.isEmpty ? [fallback] : usable
    }

    /// The newest capture worth offering, as `yyyyMMdd`.
    ///
    /// Builds from late 2025 onwards have been tried here and don't render, so listing them
    /// only wastes a several-hundred-megabyte download to learn something already known.
    private static var latestUsefulTimestamp: String {
        "20250601"
    }
}
