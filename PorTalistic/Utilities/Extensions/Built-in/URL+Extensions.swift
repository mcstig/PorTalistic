//
//  URL.swift
//  Mythic
//
//  Created by vapidinfinity (esi) on 28/1/2024.
//

// Copyright © 2023-2025 vapidinfinity

import Foundation

extension URL {
    /// Whether this location is on a volume other than the startup disk.
    ///
    /// A path test, deliberately, with no filesystem access at all: asking the volume about
    /// itself means touching it, and touching it is the thing that makes macOS put up
    /// "PorTalistic would like to access files on a removable volume".
    var isOnAnExternalVolume: Bool {
        let components = resolvingSymlinksInPath().pathComponents

        // Anything outside `/Volumes` is on the startup disk. A path that went through
        // `/Volumes/<startup disk>` has already been resolved away from it above, so it
        // lands here too.
        return components.count > 2 && components[1] == "Volumes"
    }

    /// Whether this location is on an external volume that isn't mounted right now.
    ///
    /// Tells "the disk is unplugged" apart from "the files are gone", which otherwise look
    /// identical — `fileExists` says no to both. Only the second is a reason to forget that
    /// something was ever there. Answered from the list of mounted volumes rather than by
    /// reaching for the path, for the reason above.
    var isOnAnUnmountedVolume: Bool {
        guard isOnAnExternalVolume else { return false }

        let root = "/" + resolvingSymlinksInPath().pathComponents[1...2].joined(separator: "/")
        let mounted = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil,
                                                            options: []) ?? []

        return !mounted.contains { $0.resolvingSymlinksInPath().path == root }
    }

    public var prettyPath: String {
        return path(percentEncoded: false)
            .replacingOccurrences(of: Bundle.main.bundleIdentifier!, with: "(PorTalistic)")
            .replacingOccurrences(of: "/Users/\(NSUserName())", with: "~")
            .replacingOccurrences(of: "file://", with: "")
    }
}
