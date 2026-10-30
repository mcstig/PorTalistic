// Portalistic — quitting: asking first while the VM is on screen.
//
// Command-Q sits where Alt-Q is on a PC keyboard, so it's easy to hit mid-game. While the VM
// is on screen, Command-Q and Command-W ask first: keep playing, or quit. Quitting always shuts
// the VM down (Oct 28).

import AppKit

extension AppDelegate {
    // Not while the app is moving itself to Applications: that question is asked before the main
    // window exists, so the alert closing counted as the last window closing and the app quit on
    // the spot, before the copy started (Oct 23: "Move to Applications" did nothing on a real Mac;
    // the self-test answers the question without a window, so it never saw it).
    // Quit doesn't close the app at once: the window says the VM is shutting down, and the app
    // closes once it has stopped (Oct 30: opened again right after a Quit, the app found the VM
    // still there, mid-shutdown). An update or a move to Applications sets `leaving` and quits on
    // its own terms: the VM carries on then.
    @objc func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if leaving { return .terminateNow }
        if !shuttingDown && askQuit() { shutDownThenQuit() }
        return .terminateCancel
    }

    // Closing the main window quits the app (after the same question), even with the Activity
    // window still open.
    @objc func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === window else { return true }   // the activity window just closes
        if leaving { DispatchQueue.main.async { NSApp.terminate(nil) } }
        else if !shuttingDown && askQuit() { shutDownThenQuit() }
        return false
    }

    /// While the VM is on screen, asks first (Command-Q twice quits). True to quit.
    func askQuit() -> Bool {
        let running = view?.connected ?? false
        guard running && !UserDefaults.standard.bool(forKey: dontAskKey) else { return true }
        let alert = NSAlert()
        alert.messageText = "Quit Portalistic?"
        alert.informativeText = "Steam and any game you're playing close, and the VM shuts down. "
            + "Open Portalistic again to start them again.\n\n"
            + "To free the mouse without quitting, press Control and Option together (⌃⌥)."
        alert.addButton(withTitle: "Keep Playing")
        let quit = alert.addButton(withTitle: "Quit")
        quit.keyEquivalent = "q"; quit.keyEquivalentModifierMask = [.command]   // Command-Q twice quits
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        guard alert.runModal() == .alertSecondButtonReturn else { return false }
        if alert.suppressionButton?.state == .on { UserDefaults.standard.set(true, forKey: dontAskKey) }
        return true
    }

    /// Quit always shuts the VM down, and at once (Oct 28 and 30: Michael wants it so; a VM left
    /// running with a frozen game in it couldn't be closed from the app). `bottle stop --now` saves
    /// what the VM holds in memory (10 s at most) and stops it without waiting for Steam or games.
    /// The window shows it; the app quits when it's done (or after a minute: the stop runs in a
    /// session of its own and finishes by itself; its output goes to logs/app-stop.log).
    func shutDownThenQuit() {
        shuttingDown = true
        view?.releaseMouse()
        lostTimer?.invalidate(); lostTimer = nil
        setStartScreen(true)
        startView.show("Shutting down the VM…", detail: "Portalistic closes as soon as it has stopped: a few seconds.", busy: true)
        window.makeKeyAndOrderFront(nil)
        var done = false
        let quit = { [weak self] in
            guard let self = self, !done else { return }
            done = true
            self.leaving = true
            NSApp.terminate(nil)
        }
        let c = BottleCommand(["stop", "--now"], log: "stop")
        c.onExit = { _ in quit() }
        quietCommands.append(c)
        guard c.start() else { quit(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { quit() }
    }
}
