//
//  Logger.swift
//  Mythic
//
//  Created by vapidinfinity (esi) on 16/9/2023.
//

// Copyright © 2023-2025 vapidinfinity

import Foundation
import OSLog

extension Logger {
    nonisolated(unsafe) static var subsystem = Bundle.main.bundleIdentifier!
    
    /**
     Returns a custom logger instance with the specified category.
     
     - Parameter category: The category for the custom logger.
     - Returns: A custom logger instance.
     */
    static func custom(category: String) -> Logger {
        return Logger(subsystem: subsystem, category: category)
    }
    
    /// Logger instance for network-related logs.
    static let network = custom(category: "network")
    
    /// Logger instance for app-related logs.
    static let app = custom(category: "app")
    
    /// Logger instance for file-related logs.
    static let file = custom(category: "file")
}

// MARK: - Render counting

#if DEBUG
/**
 Counts view-body evaluations and logs a summary once a second.

 Guessing at SwiftUI performance is expensive, and the two explanations look identical from
 the outside: too much work in one body, or far too many bodies. This separates them.

 Off unless asked for, because it logs once a second forever:

     defaults write com.mcstig.PorTalistic logRenderCounts -bool true

 A line like `bodies/s: GameCard×2400  CardArtwork×2400  GameListView×40` says something
 invalidates the whole grid forty times a second. `GameCard×60` while scrolling says the
 renders are fine and the cost is inside one of them.
 */
enum RenderCounter {
    private static let log: Logger = .custom(category: "render")

    /// Read once. `UserDefaults` on every body evaluation would be its own performance
    /// problem, and would not be measuring what it claims to.
    private static let isEnabled: Bool = UserDefaults.standard.bool(forKey: "logRenderCounts")

    /// `nonisolated(unsafe)` with a lock around every access, which is the same arrangement
    /// the update-availability memos use: this is read and written from view bodies on the
    /// main actor, and the lock is there for the case where it isn't.
    private static let lock: NSLock = .init()
    private nonisolated(unsafe) static var counts: [String: Int] = .init()
    private nonisolated(unsafe) static var lastFlush: Date = .now

    static func record(_ name: String) {
        guard isEnabled else { return }

        lock.lock()
        counts[name, default: 0] += 1

        guard Date.now.timeIntervalSince(lastFlush) >= 1 else {
            lock.unlock()
            return
        }

        let snapshot = counts
        counts = .init()
        lastFlush = .now
        lock.unlock()

        let summary = snapshot
            .sorted { $0.value > $1.value }
            .map { "\($0.key)×\($0.value)" }
            .joined(separator: "  ")

        log.notice("bodies/s: \(summary, privacy: .public)")
    }
}
#endif
