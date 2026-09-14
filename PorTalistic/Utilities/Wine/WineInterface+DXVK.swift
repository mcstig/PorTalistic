//
//  WineInterface+DXVK.swift
//  Mythic
//
//  Created by vapidinfinity (esi) on 11/11/2025.
//

// Copyright © 2023-2025 vapidinfinity

import Foundation

extension Wine {
    final class DXVK {
        /// Removes DXVK's DLLs from a container, so Wine's own Direct3D is used again.
        ///
        /// ``install(toContainerAtURL:)`` overwrites the prefix's Direct3D DLLs and there was
        /// no way back: turning DXVK off in a container's settings left the DLLs exactly
        /// where they were, so the setting said one thing and the prefix did another. That
        /// matters most when a container has since moved to a newer Wine, because the DLLs
        /// left behind are the ones the *old* engine shipped.
        ///
        /// Deleting them is the whole job — Wine falls back to its built-in implementations
        /// when the files aren't there.
        static func uninstall(fromContainerAtURL containerURL: URL) async throws {
            try Wine.killAll(at: containerURL)

            for directory in ["system32", "syswow64"] {
                for name in replacedDLLs {
                    try FileManager.default.removeItemIfExists(
                        at: containerURL.appending(path: "drive_c/windows/\(directory)/\(name)")
                    )
                }
            }
        }

        /// Whether DXVK's DLLs are present in a container.
        static func isInstalled(inContainerAtURL containerURL: URL) -> Bool {
            FileManager.default.fileExists(
                atPath: containerURL.appending(path: "drive_c/windows/system32/d3d11.dll").path
            )
        }

        /// The DLLs DXVK replaces, and that ``uninstall(fromContainerAtURL:)`` takes back out.
        ///
        /// `dxgi` is in this list on purpose. DXVK's d3d11 enumerates adapters through DXVK's
        /// own dxgi over a private interface; ship one without the other and
        /// `D3D11CreateDevice` fails on an adapter it doesn't recognise, and the app silently
        /// lands back on wined3d.
        static let replacedDLLs = ["dxgi.dll", "d3d10core.dll", "d3d11.dll"]

        /// Replaces the Engine’s DirectX DLLs in the specified Wine container with their DXVK equivalents.
        static func install(toContainerAtURL containerURL: URL) async throws {
            try Wine.killAll(at: containerURL)

            for (architecture, directory) in [("x64", "system32"), ("x32", "syswow64")] {
                for name in replacedDLLs {
                    let source = Engine.directory.appending(path: "DXVK/\(architecture)/\(name)")

                    // Not every DXVK build ships every DLL — d3d10core came and went across
                    // releases — so a missing source is a skip, not a failure that leaves the
                    // prefix half-converted.
                    guard FileManager.default.fileExists(atPath: source.path) else {
                        Wine.log.notice("DXVK build has no \(architecture)/\(name); leaving the container's copy alone.")
                        continue
                    }

                    try FileManager.default.removeItemIfExists(
                        at: containerURL.appending(path: "drive_c/windows/\(directory)/\(name)")
                    )
                    try FileManager.default.forceCopyItem(
                        at: source,
                        to: containerURL.appending(path: "drive_c/windows/\(directory)")
                    )
                }
            }
        }

        // to remove DXVK, you must run wineboot in update mode
    }
}
