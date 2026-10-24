// Portalistic — a few things to know, shown once when the app is first on screen (Oct 23: Michael
// wants new users told that some games need a second or third start), and from the app menu after.

import AppKit

extension AppDelegate {
    static let tipsShownKey = "ShownFirstStartTips"

    /// The first time the VM's screen is up on this Mac: the tips, once.
    func showFirstStartTipsIfNew() {
        guard !UserDefaults.standard.bool(forKey: AppDelegate.tipsShownKey), !inSelfTest else { return }
        UserDefaults.standard.set(true, forKey: AppDelegate.tipsShownKey)
        showTips(first: true)
    }

    @objc func showTipsMenu(_ sender: Any?) { showTips(first: false) }

    func showTips(first: Bool) {
        let alert = NSAlert()
        alert.messageText = first ? "Welcome to Portalistic" : "Good to know"
        alert.informativeText = """
            Steam runs in a small Linux system on this Mac, and Windows games run through Proton. A few things to know:

            • Some games don't start on the first try. If a game closes right away or shows nothing, start it a second or third time: the first start sets up the game's Windows folder, which can take a few minutes, and Portalistic tells you when that's happening.

            • If Steam itself seems stuck, choose Steam > Restart Steam.

            • Games with anti-cheat (and some with copy protection) won't run here; Portalistic doesn't work around that.

            • Press ⌘ Esc to free the mouse while a game has it. ⌃⌘F is full screen.

            This is here again under Portalistic > Good to Know…
            """
        alert.addButton(withTitle: "OK")
        if let w = window, w.isVisible {
            alert.beginSheetModal(for: w) { _ in }
        } else {
            alert.runModal()
        }
    }
}
