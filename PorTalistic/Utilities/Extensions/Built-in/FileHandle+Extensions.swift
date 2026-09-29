//
//  FileHandle+Extensions.swift
//  Mythic
//
//  Created by vapidinfinity (esi) on 12/12/2025.
//

// Copyright © 2023-2025 vapidinfinity

import Foundation

/// `read(2)`, retried through `EINTR`.
///
/// At file scope on purpose, and it cannot move into the extension below: inside
/// `extension FileHandle` the unqualified name `read` binds to the member
/// `FileHandle.read(upToCount:)` and never falls through to the global, so the call does not
/// compile at all — and the module-qualified spelling that would fix it differs by platform
/// (`Darwin.read`, `SwiftGlibc.read`). Out here there is no member to shadow it.
///
/// - Returns: the number of bytes read, `0` at end of file, or a negative number for a handle
///   that has gone.
private func posixRead(_ descriptor: Int32, into buffer: inout [UInt8]) -> Int {
    var count = 0

    repeat {
        count = read(descriptor, &buffer, buffer.count)
    } while count < 0 && errno == EINTR

    return count
}

extension FileHandle {
    /// A bridge for `readabilityHandler` callbacks, using AsyncStream.
    /// - Note: This stream automatically handles empty handle data.
    ///
    /// Reads with `read(2)` rather than `availableData`, which *raises*
    /// `NSFileHandleOperationException` on a read error — an `NSException`, which Swift cannot
    /// catch, so it is a crash rather than an error. `EBADF` is reachable here by ordinary
    /// means: `Process.runStreamed` closes these handles from the process's termination
    /// handler, which runs on a Foundation queue, while this callback runs on a libdispatch
    /// queue with nothing synchronising the two — so a callback already scheduled when the
    /// process exits reads a descriptor that has just been closed. Every download, every launch
    /// and every metadata fetch comes through here.
    ///
    /// **Not** `read(upToCount:)`, which is the obvious throwing replacement and is wrong: it
    /// blocks until it has the full count or the pipe reaches EOF, where `availableData`
    /// returns as soon as there is anything. Measured, that turns line-at-a-time output into
    /// one delivery at exit — which freezes the progress bar, stops `fetchMetadata` from
    /// interrupting legendary early, and deadlocks an install outright: legendary writes its
    /// optional-packs prompt and waits for stdin, while the reader waits for 64KB that cannot
    /// arrive because legendary is waiting for the reply.
    ///
    /// `read(2)` has `availableData`'s semantics — return what is there — and reports failure
    /// in `errno` instead of raising. A failed read is treated as end-of-file, which is what it
    /// is: on a blocking pipe the realistic errors are `EBADF` (the handle has been closed,
    /// the case this exists to survive) and `EIO`. `EAGAIN` cannot occur, because these pipes
    /// are not `O_NONBLOCK`; `EINTR` can, and is retried rather than mistaken for the end.
    var readabilityDataStream: AsyncStream<Data> {
        AsyncStream { continuation in
            self.readabilityHandler = { [weak self] handle in
                var buffer: [UInt8] = .init(repeating: 0, count: 65_536)
                let count = posixRead(handle.fileDescriptor, into: &buffer)

                // 0 is end of file; negative is a handle that has gone. Both mean nothing
                // further is coming.
                guard count > 0 else {
                    continuation.finish()
                    self?.readabilityHandler = nil
                    return
                }
                
                continuation.yield(Data(buffer[0..<count]))
            }
            
            continuation.onTermination = { [weak self] _ in
                self?.readabilityHandler = nil
            }
        }
    }
}
