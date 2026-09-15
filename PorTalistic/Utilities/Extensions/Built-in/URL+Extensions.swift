//
//  URL.swift
//  Mythic
//
//  Created by vapidinfinity (esi) on 28/1/2024.
//

// Copyright © 2023-2025 vapidinfinity

import Foundation

extension URL {
    /// Whether this location is on a volume that isn't mounted at the moment.
    ///
    /// Tells "the disk is unplugged" apart from "the files are gone", which otherwise look
    /// identical — `fileExists` says no to both. Only the second is a reason to forget that
    /// something was ever there.
    var isOnAnUnmountedVolume: Bool {
        let components = resolvingSymlinksInPath().pathComponents

        // Anything outside `/Volumes` is on the startup disk, which is always mounted. A
        // path that went through `/Volumes/<startup disk>` has already been resolved away
        // from it by the line above, so it lands here too.
        guard components.count > 2, components[1] == "Volumes" else { return false }

        return !FileManager.default.fileExists(atPath: "/Volumes/\(components[2])")
    }

    public var prettyPath: String {
        return path(percentEncoded: false)
            .replacingOccurrences(of: Bundle.main.bundleIdentifier!, with: "(PorTalistic)")
            .replacingOccurrences(of: "/Users/\(NSUserName())", with: "~")
            .replacingOccurrences(of: "file://", with: "")
    }
}
