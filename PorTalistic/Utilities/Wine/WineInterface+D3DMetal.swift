//
//  WineInterface+D3DMetal.swift
//  Mythic
//
//  Created by Claude Opus 5 on 14/9/2026.
//

// Copyright © 2023-2025 vapidinfinity

import Foundation

extension Wine {
    /**
     Apple's Direct3D-on-Metal, as laid down by the Game Porting Toolkit.

     Detection only. Mythic never installs this and never will: Apple's Game Porting Toolkit
     licence restricts distribution of its proprietary components to non-commercial purposes,
     and this is a paid product. What it *can* do is notice that a machine already has it —
     someone who installed the Game Porting Toolkit, or Whisky, or CrossOver, holds their own
     licence for their own copy, and is entitled to the more mature Direct3D path that DXMT is
     still catching up to.

     So this is the opportunistic half of the story: DXMT is what Mythic ships and what every
     machine can rely on, and this is a better answer where it happens to be available.
     */
    enum D3DMetal {
        /// The marker, measured rather than assumed.
        ///
        /// `lib/external/D3DMetal.framework` — beside `libd3dshared.dylib` — turned up in the
        /// bundled engine, in `/Applications/Game Porting Toolkit.app`, and in Whisky's Wine
        /// library, and was absent from Sikarugir (which advertises `no_d3dmetal` outright),
        /// mainline Wine 11 and Homebrew's wine. One path distinguishes every runtime on a
        /// real machine, so one path is what this checks.
        private static let frameworkSubpath = "lib/external/D3DMetal.framework"

        /// Whether this runtime carries Apple's implementation.
        ///
        /// Note what this deliberately does not care about: how the runtime got there. The
        /// bundled engine is Game Porting Toolkit derived and answers true, which is worth
        /// knowing on its own — it is why shipping the engine is a licensing question and not
        /// just a hosting one.
        static func isPresent(in runtime: Runtime) -> Bool {
            var isDirectory: ObjCBool = false
            let path = DXMT.wineRoot(of: runtime).appending(path: frameworkSubpath).path

            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
                return false
            }

            // A framework is a directory. Requiring that rules out a stray file of the same
            // name standing in for a working implementation.
            return isDirectory.boolValue
        }
    }
}
