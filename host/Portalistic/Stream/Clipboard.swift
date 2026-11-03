// Portalistic — the clipboard between the Mac and the VM (screen protocol version 4, CLIPBOARD).
//
// Before the app had its own window, Screen Sharing carried the clipboard over VNC; the app's
// stream (bottle-screen) carried only the picture and input until Nov 3, 2026. Now text copied
// on the Mac can be pasted in the VM (Ctrl+V, or ⌘V in the window), and text copied in the VM
// (Ctrl+C, or ⌘C) lands on the Mac's clipboard. Text only, up to 1 MB either way.
//
// The Mac's side is sent when it changed: when the window gets the keyboard, once a second
// while it has it, and right before a paste key reaches the VM (so the paste gets the newest
// text). Only the change count is looked at until then; the text itself is read only when it
// changed. Items a password manager marks as concealed go across only on a paste key, never
// in the background.

import AppKit

final class ClipboardSync: NSObject {         // (NSObject: its timer calls an @objc method)
    static let maxBytes = 1 << 20                 // bottle-screen's CLIP_MAX
    private static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    private let conn: Connection
    private var seenCount = -1                    // the Mac pasteboard's changeCount last looked at
    private var lastText: String?                 // the last text that crossed, either way
    private var timer: Timer?

    init(conn: Connection) {
        self.conn = conn
        super.init()
    }

    /// A new connection: the VM's clipboard starts empty, so the Mac's text goes over again.
    func connected() {
        seenCount = -1
        lastText = nil
        pushIfChanged()
    }

    /// While the window has the keyboard, the Mac's clipboard is looked at once a second.
    func setActive(_ on: Bool) {
        timer?.invalidate()
        timer = nil
        guard on else { return }
        pushIfChanged()
        timer = Timer.scheduledTimer(timeInterval: 1, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
    }

    @objc private func tick() { pushIfChanged() }

    /// The Mac's text to the VM, if the clipboard changed since the last look. `forPaste`: a
    /// paste key is on its way to the VM (concealed items go too, and even an unchanged text is
    /// sent again if something in the VM was copied since). Main thread.
    func pushIfChanged(forPaste: Bool = false) {
        guard conn.serverVersion >= 4 else { return }   // an older screen server drops the app for a message over 1 KB
        let pb = NSPasteboard.general
        let count = pb.changeCount
        guard count != seenCount || forPaste else { return }
        let types = pb.types ?? []
        if !forPaste && (types.contains(Self.concealed) || types.contains(Self.transient)) {
            seenCount = count                     // a password: only when the player pastes it
            return
        }
        seenCount = count
        guard let text = pb.string(forType: .string), !text.isEmpty, text != lastText else { return }
        let bytes = Array(text.utf8)
        guard bytes.count <= Self.maxBytes else { return }
        lastText = text
        conn.send(ClientMsg.clipboard, bytes)
    }

    /// Text copied in the VM: onto the Mac's clipboard. Main thread.
    func received(_ text: String) {
        guard !text.isEmpty else { return }
        lastText = text
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        seenCount = pb.changeCount                // ours: not sent back
    }
}
