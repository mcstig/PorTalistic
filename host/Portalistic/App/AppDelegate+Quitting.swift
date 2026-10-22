// Portalistic — quitting: asking first while the VM is on screen.
//
// Command-Q sits where Alt-Q is on a PC keyboard, so it's easy to hit mid-game. While the VM
// is on screen, Command-Q and Command-W ask first: keep playing, quit (the VM carries on), or
// quit and shut the VM down.

import AppKit

extension AppDelegate {
    // Not while the app is moving itself to Applications: that question is asked before the main
    // window exists, so the alert closing counted as the last window closing and the app quit on
    // the spot, before the copy started (Oct 23: "Move to Applications" did nothing on a real Mac;
    // the self-test answers the question without a window, so it never saw it).
    @objc func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !installing }

    @objc func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        confirmLeaving() ? .terminateNow : .terminateCancel
    }

    // Closing the main window quits the app (after the same question), even with the Activity
    // window still open.
    @objc func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === window else { return true }   // the activity window just closes
        if confirmLeaving() { DispatchQueue.main.async { NSApp.terminate(nil) } }
        return false
    }

    func confirmLeaving() -> Bool {
        if leaving || !(view?.connected ?? false) || UserDefaults.standard.bool(forKey: dontAskKey) { leaving = true; return true }
        let alert = NSAlert()
        alert.messageText = "Quit Portalistic?"
        alert.informativeText = "Steam and any game you're playing keep running in the VM, unless you shut it down too. "
            + "Open Portalistic again to get back to them.\n\n"
            + "To free the mouse without quitting, press ⌘Esc."
        alert.addButton(withTitle: "Keep Playing")
        let quit = alert.addButton(withTitle: "Quit")
        quit.keyEquivalent = "q"; quit.keyEquivalentModifierMask = [.command]   // Command-Q twice quits
        alert.addButton(withTitle: "Quit and Shut Down the VM")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again (Quit leaves the VM running)"
        switch alert.runModal() {
        case .alertSecondButtonReturn:
            if alert.suppressionButton?.state == .on { UserDefaults.standard.set(true, forKey: dontAskKey) }
        case .alertThirdButtonReturn:
            // Carries on after the app has quit (its output goes to logs/app-stop.log).
            let c = BottleCommand(["stop"], log: "stop")
            _ = c.start()
            quietCommands.append(c)
        default:
            return false
        }
        leaving = true
        return true
    }
}
