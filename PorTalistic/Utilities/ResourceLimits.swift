//
//  ResourceLimits.swift
//  Mythic
//
//  Created by Claude (Cowork) on 6/9/2026.
//

// Copyright © 2023-2025 vapidinfinity

import Foundation
import OSLog

/**
 Process resource limits that Wine and everything it launches inherit from Mythic.

 Wine's msync (the macOS relative of Linux's esync/fsync) backs every Win32 synchronisation
 object — every event, mutex and semaphore — with a real file descriptor. Windows programs
 create these in the thousands without thinking about it, because on Windows they cost
 almost nothing.

 macOS starts a process with a soft `RLIMIT_NOFILE` of 256. The Steam client exhausts that
 during startup and then dies on its own assertion:

 ```
 src\tier0\threadtools.cpp (1899) : Thread synchronization object is unuseable
 ```

 which is Valve's way of saying a `CreateEvent` came back empty-handed. Nothing about the
 message points at file descriptors, and nothing in Mythic's own logs does either — it
 simply looks like Steam crashing for no reason a few minutes in.

 The soft limit is ours to raise, up to the hard limit, without any privilege. Doing it once
 at launch fixes it for every process Mythic spawns, so this is not a Steam workaround —
 it's the same failure any msync-enabled game would hit.
 */
enum ResourceLimits {
    private static let log: Logger = .custom(category: "ResourceLimits")

    /// macOS refuses values above `OPEN_MAX` for the soft limit, and asking for more fails
    /// the whole call rather than clamping, so ask for something it will accept.
    private static let desiredOpenFileLimit: rlim_t = 65_536

    /// `RLIM_INFINITY` is a C macro that doesn't survive the import into Swift.
    private static let unlimited: rlim_t = .init(UInt64(1) << 63) - 1

    /// Raise this process's open-file soft limit as far as the system allows.
    ///
    /// Safe to call more than once. Failure is logged and otherwise ignored: a lowered
    /// limit degrades msync-heavy games, it doesn't stop Mythic working.
    static func raiseOpenFileLimit() {
        var limit: rlimit = .init()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else {
            log.warning("Couldn't read the open-file limit: \(String(cString: strerror(errno)), privacy: .public)")
            return
        }

        let target: rlim_t = limit.rlim_max == unlimited
            ? desiredOpenFileLimit
            : min(desiredOpenFileLimit, limit.rlim_max)

        guard target > limit.rlim_cur else {
            log.debug("Open-file limit already \(limit.rlim_cur); leaving it alone.")
            return
        }

        let previous = limit.rlim_cur
        limit.rlim_cur = target

        guard setrlimit(RLIMIT_NOFILE, &limit) == 0 else {
            log.warning("Couldn't raise the open-file limit to \(target): \(String(cString: strerror(errno)), privacy: .public)")
            return
        }

        log.notice("Raised the open-file limit from \(previous) to \(target).")
    }

    /// The current open-file limits, phrased for a diagnostics report.
    static var openFileLimitDescription: String? {
        var limit: rlimit = .init()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return nil }
        let hard = limit.rlim_max == unlimited ? "unlimited" : String(limit.rlim_max)
        return "\(limit.rlim_cur) soft / \(hard) hard"
    }
}
