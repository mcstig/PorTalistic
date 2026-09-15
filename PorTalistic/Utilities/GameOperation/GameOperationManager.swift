//
//  GameOperationManager.swift
//  Mythic
//
//  Created by vapidinfinity (esi) on 16/11/2025.
//

// Copyright © 2023-2025 vapidinfinity

import Foundation
import OSLog
import Observation
import UserNotifications
import AppKit
import DockProgress

@Observable @MainActor final class GameOperationManager {
    static var shared: GameOperationManager = .init()
    private let log: Logger = .custom(category: "GameOperationManager")

    // ‼️ operationqueue should NOT be accessed outside, this will always be private
    // cannot name this _queue, swiftui seems to automatically insert _queue for the queue variable
    // avoid naming 'underlyingQueue', this is already a variable
    // swiftlint:disable:next identifier_name
    var _operationQueue: OperationQueue
    /// The operation the interface should show for a game, if any.
    ///
    /// Defined once here because three places were asking the same question of the queue
    /// with the same predicate written out by hand.
    func operation(for game: Game) -> GameOperation? {
        queue.first { $0.game == game && ($0.isExecuting || $0.type.modifiesFiles) }
    }

    // necessitated by deprecation of `OperationQueue.operations`
    internal private(set) var queue: [GameOperation] = .init() {
        didSet {
            if let currentOperation = self.queue.first(where: { $0.type.modifiesFiles && $0.isExecuting }) {
                Task { @MainActor in
                    DockProgress.style = .badge(color: .accentColor, badgeValue: { self.queue.filter({ $0.type.modifiesFiles }).count })
                    DockProgress.progressInstance = currentOperation.progressKVOBridge._progress
                }
            }
        }
    }

    private init() {
        let queue: OperationQueue = .init()
        queue.name = "GameOperationManagerQueue"
        queue.maxConcurrentOperationCount = .max
        queue.qualityOfService = .utility
        
        self._operationQueue = queue
    }

    private func removeFromOverlyingQueue(_ operation: GameOperation) {
        queue.removeAll(where: { $0 == operation })
    }

    func queueOperation(_ operation: GameOperation) {
        // prevent concurrent operations from modifying the same game, potentially causing data races
        for existingOperation in queue where existingOperation.game == operation.game {
            operation.addDependency(existingOperation)
        }
        
        // FIXME: Legendary has a self-managed datalock, so we must queue those operations serially
        if case .epicGames = operation.game.storefront, operation.type.modifiesFiles {
            for existingOperation in queue where existingOperation.game.storefront == .epicGames && existingOperation.type.modifiesFiles {
                operation.addDependency(existingOperation)
            }
        }
        
        let originalCompletionBlock = operation.completionBlock
        operation.completionBlock = { [self] in
            // run code that was already in the completion block
            originalCompletionBlock?()
            
            // remove operation from `queue` on operation completion,
            // this ensures `queue` is always mirroring `operationQueue`.
            Task { await removeFromOverlyingQueue(operation) }

            // present any unhandled errors within the operation to the ui.
            Task { @MainActor in
                guard let error = operation.error else { return }

                let alert = NSAlert()
                alert.messageText = String(localized: "Unable to complete operation [\(operation.description)].")
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .critical
                alert.addButton(withTitle: String(localized: "OK"))

                // This used to be `NSApp.windows.first`, and that is how a failed launch
                // became "nothing happens". `windows.first` is whatever window happens to be
                // first — the About panel, or a Settings window the user had dragged onto
                // another display — and worse, a window can host only one sheet: attach an
                // alert to a window that already has one and it waits, invisibly, for the
                // first to be dismissed. Which it may never be.
                //
                // So: the window the user is actually looking at, and only if it is free.
                // Otherwise a plain modal, which cannot be hidden behind anything.
                let candidate = NSApp.keyWindow ?? NSApp.mainWindow

                if let window = candidate, window.attachedSheet == nil, window.isVisible {
                    alert.beginSheetModal(for: window)
                } else {
                    NSApp.activate()
                    alert.runModal()
                }
            }

            // display completion notification to user
            Task {
                // ensure operation actually completed
                guard operation.type.modifiesFiles else { return }
                guard !operation.isCancelled else { return }
                
                let notificationContent: UNMutableNotificationContent = .init()
                notificationContent.title = String(localized: "Operation complete.")
                notificationContent.body = String(localized: "\(operation.game.description) is now ready.")
                notificationContent.interruptionLevel = .active

                let notificationRequest: UNNotificationRequest = .init(
                    identifier: "GameOperationCompletion_\(operation.id)",
                    content: notificationContent,
                    trigger: nil
                )

                do {
                    try await UNUserNotificationCenter.current().add(notificationRequest)
                } catch {
                    log.error("Unable to send notification for operation completion: \(error.localizedDescription)")
                }
            }
            
            // FIXME: dirtyfix: refresh from storefronts after installation to update instances
            // FIXME: of this operation's associated game with its new installation values,
            // FIXME: since GameDataStore.refreshFromStorefronts is needed to re-sync file status
            // to fix this, legendary's JSONs must be monitored using an API like FSEvents.
            // but this is way simpler rofl
            if case .epicGames = operation.game.storefront, operation.type.modifiesFiles {
                Task(priority: .utility, operation: { try? await GameDataStore.shared.refreshFromStorefronts(.epicGames) })
            }
            
            log.debug("Operation \(operation.debugDescription) complete.")
        }

        _operationQueue.addOperation(operation)
        queue.append(operation)

        log.debug("Queued operation \(operation.debugDescription)\(operation.dependencies.isEmpty ? "." : "with dependencies \(operation.dependencies.map(\.description).formatted(.list(type: .and)))")")
    }

    func cancelAllOperations() {
        log.debug("Cancelling all (\(self.queue.count)) operations.")
        _operationQueue.cancelAllOperations()
        queue.removeAll()
        log.debug("Cancelled all operations, and cleared queues.")
    }
}
