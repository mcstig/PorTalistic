// Portalistic — asking macOS for local-network access (Oct 23). The VM's traffic leaves through this
// app's processes, and macOS lets an app reach other machines on the LAN only once the user has
// allowed it (System Settings > Privacy & Security > Local Network). The prompt comes the first
// time the app looks for something on the network: a short Bonjour browse does that, once the VM
// is up. Without the permission the Linux desktop reaches the router and this Mac only.

import Foundation
import Network

final class LocalNetworkAccess {
    static let shared = LocalNetworkAccess()
    private var browser: NWBrowser?
    private var asked = false

    /// A few seconds of Bonjour browsing for SMB servers: enough for macOS to ask the user.
    func ask() {
        guard !asked else { return }
        asked = true
        let b = NWBrowser(for: .bonjour(type: "_smb._tcp", domain: nil), using: .tcp)
        b.stateUpdateHandler = { _ in }
        b.browseResultsChangedHandler = { _, _ in }
        b.start(queue: .main)
        browser = b
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.browser?.cancel()
            self?.browser = nil
        }
    }
}
