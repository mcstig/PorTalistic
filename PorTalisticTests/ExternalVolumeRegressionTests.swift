//
//  ExternalVolumeRegressionTests.swift
//  PorTalisticTests
//
//  Created by Claude Opus 5 on 15/9/2026.
//

// Copyright © 2023-2025 vapidinfinity

import Foundation
import Testing

@testable import PorTalistic

/**
 Where a game's files are, answered without going to look.

 Two separate faults sit behind this. Asking a volume about itself is what made macOS put up
 "PorTalistic would like to access files on a removable volume" on every single launch, so
 these have to stay path tests. And unplugging an external disk destroyed a GOG install
 record, because "the files are gone" and "the disk isn't here" both look like `fileExists`
 saying no, and only the first is a reason to forget a game was installed.
 */
@Suite("External volumes")
struct ExternalVolumeRegressionTests {
    @Test("A path on another volume is recognised")
    func externalVolumePathsAreRecognised() {
        #expect(URL(filePath: "/Volumes/Crucial X9/Games/Prey").isOnAnExternalVolume)
        #expect(URL(filePath: "/Volumes/Crucial X9").isOnAnExternalVolume)
    }

    @Test("Paths on the startup disk are not external")
    func startupDiskPathsAreNotExternal() {
        #expect(URL(filePath: "/Users/someone/Games/Prey").isOnAnExternalVolume == false)
        #expect(URL(filePath: "/Applications").isOnAnExternalVolume == false)
        #expect(URL(filePath: "/").isOnAnExternalVolume == false)
        #expect(URL(filePath: "/Volumes").isOnAnExternalVolume == false,
                "`/Volumes` itself is on the startup disk")
    }

    @Test("The startup disk reached through /Volumes is still the startup disk")
    func startupDiskThroughVolumesIsNotExternal() throws {
        let name = try #require(try URL(filePath: "/").resourceValues(forKeys: [.volumeNameKey]).volumeName)
        let entry: URL = .init(filePath: "/Volumes/\(name)")

        // Only where macOS actually publishes that entry as a link back to the root. Where it
        // is a real mount point there is nothing to resolve and nothing to assert.
        let isLink = (try? entry.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink ?? false
        guard isLink else { return }

        #expect(entry.appending(path: "Users").isOnAnExternalVolume == false)
    }

    @Test("A volume that isn't mounted is told apart from files that are gone")
    func unmountedVolumesAreToldApart() {
        let onADiskThatIsNotHere: URL = .init(filePath: "/Volumes/\(UUID().uuidString)/Games/Prey")

        #expect(onADiskThatIsNotHere.isOnAnExternalVolume)
        #expect(onADiskThatIsNotHere.isOnAnUnmountedVolume,
                "an unplugged disk is not a reason to forget a game was ever installed")
    }

    @Test("Nothing on the startup disk is ever reported as unmounted")
    func startupDiskIsNeverUnmounted() {
        #expect(URL.homeDirectory.appending(path: "Games").isOnAnUnmountedVolume == false)
        #expect(URL(filePath: "/Applications").isOnAnUnmountedVolume == false)
    }

    @Test("A mounted external volume is not reported as unmounted")
    func mountedExternalVolumesAreNotUnmounted() throws {
        let mounted = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil,
                                                            options: [.skipHiddenVolumes]) ?? []
        let external = mounted.filter(\.isOnAnExternalVolume)

        // Nothing to say on a machine with no external disk attached, which is most of them.
        for volume in external {
            #expect(volume.appending(path: "Games").isOnAnUnmountedVolume == false,
                    "\(volume.path) is attached right now")
        }
    }
}
