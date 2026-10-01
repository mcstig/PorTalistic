//
//  Global.swift
//  Mythic
//
//  Created by vapidinfinity (esi) on 11/10/2023.
//

// Copyright © 2023-2025 vapidinfinity

import Foundation
import SwiftUI
import UserNotifications
import SwordRPC
import SemanticVersion

nonisolated(unsafe) let discordRPC: SwordRPC = .init(appId: "1191343317749870712")

var appVersion: SemanticVersion? {
    guard let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
          let bundleVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
          let appVersion: SemanticVersion = .init("\(shortVersion)+\(bundleVersion)") else {
        return nil
    }

    return appVersion
}

/// The version this copy of the app carries, the way the update prompt names versions: `0.6.20 (74)`.
///
/// Not `appVersion?.description` — `SemanticVersion`'s description here prints only the first
/// two parts, so 0.6.2 build 70 read "0.6+70" in the update prompt, and 0.6.20 would have read
/// the same "0.6". Two versions that differ only where it matters, shown as one.
var appVersionDescription: String {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    return "\(version) (\(build))"
}
