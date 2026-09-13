//
//  NetworkMonitor.swift
//  Mythic
//
//  Created by vapidinfinity (esi) on 8/2/2024.
//

// Reference: https://arc.net/l/quote/ivjknjyv

// Copyright © 2023-2025 vapidinfinity

import Foundation
import Network
import SwiftUI
import OSLog

final class NetworkMonitor: ObservableObject, @unchecked Sendable {
    static let shared: NetworkMonitor = .init()

    private let monitor: NWPathMonitor = .init()
    private let queue: DispatchQueue = .init(label: "NetworkMonitor", qos: .background)

    @MainActor @Published private(set) var isConnected: Bool = false

    @MainActor @Published private(set) var epicAccessibilityState: NetworkAccessibility?
    enum NetworkAccessibility {
        case accessible
        case checking
        case inaccessible
    }

     private init() {
         monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }

            Task { @MainActor in
                self.isConnected = (path.status == .satisfied)

                if self.isConnected {
                    try? await self.checkEpicAccessibility()
                }
            }
        }

         monitor.start(queue: queue)
    }

    /// Whether the storefront a game came from can be reached right now.
    ///
    /// Epic gets a real reachability check because `legendary` fails opaquely without one.
    /// Everything else is asked the only question that can be answered without a probe per
    /// storefront — is there a network at all — rather than being gated on Epic's answer,
    /// which is what used to happen and which made a GOG download impossible whenever
    /// epicgames.com was slow.
    @MainActor func isReachable(for storefront: Game.Storefront?) -> Bool {
        switch storefront {
        case .some(.epicGames): epicAccessibilityState == .accessible
        case .some(.local):     true
        default:                isConnected
        }
    }

    private func checkEpicAccessibility() async throws {
        await MainActor.run {
            self.epicAccessibilityState = .checking
        }

        let request = URLRequest(
            url: .init(string: "https://epicgames.com")!,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: .init(5)
        )

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }

            // Anything that answered is good enough to call Epic reachable. Restricting this
            // to 2xx meant a redirect, a bot-protection 403, or a maintenance page put the
            // app into offline mode for the whole session.
            let reachable = httpResponse.statusCode < 500
            await MainActor.run {
                self.epicAccessibilityState = reachable ? .accessible : .inaccessible
            }
        } catch {
            // Leaving this as `.checking` on failure stranded the app in a state that reads
            // as "not accessible" forever. Record the real outcome instead.
            Logger.app.warning("Epic reachability check failed: \(error.localizedDescription)")
            await MainActor.run {
                self.epicAccessibilityState = .inaccessible
            }
            throw error
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(NetworkMonitor.shared)
}
