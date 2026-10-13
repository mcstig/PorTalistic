// Portalistic — the Activity window: the output of the Bottle menu's longer jobs.

import AppKit

/// The output of the Bottle menu's longer jobs (update, logs, restarting Steam, shutting down).
final class ActivityWindow: NSWindowController {
    private let text: NSTextView
    private let status = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private(set) var command: BottleCommand?
    private let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 400),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "Portalistic Activity"
        w.isReleasedWhenClosed = false
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.isEditable = false
        tv.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.textContainerInset = NSSize(width: 6, height: 6)
        text = tv
        super.init(window: w)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        status.lineBreakMode = .byTruncatingTail
        let bar = NSStackView(views: [spinner, status])
        bar.orientation = .horizontal
        bar.spacing = 8
        let content = NSView()
        for v in [scroll, bar] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -12),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
        ])
        w.contentView = content
        if !w.setFrameUsingName("SteamOSBottleActivity") { w.center() }
        w.setFrameAutosaveName("SteamOSBottleActivity")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var busy: Bool { command?.running ?? false }
    var onFinish: (() -> Void)?                 // after any job ends

    /// Runs `bottle args...` here; `then` gets its exit status and the command.
    func run(_ title: String, _ args: [String], log: String, then: ((Int32, BottleCommand) -> Void)? = nil) {
        guard !busy else { showWindow(nil); return }
        let c = BottleCommand(args, log: log)
        text.string = ""
        status.stringValue = title + "…"
        spinner.startAnimation(nil)
        c.onLine = { [weak self] line in self?.append(line) }
        c.onExit = { [weak self, unowned c] code in
            guard let self = self else { return }
            self.spinner.stopAnimation(nil)
            self.status.stringValue = code == 0 ? title + ": done." : title + ": didn't work (see above)."
            then?(code, c)
            self.onFinish?()
        }
        command = c
        window?.title = title
        showWindow(nil)
        if !c.start() {
            spinner.stopAnimation(nil)
            status.stringValue = "Couldn't run the bottle command (\(BottleCommand.script ?? "no kit folder"))."
        }
    }

    private func append(_ line: String) {
        text.textStorage?.append(NSAttributedString(string: line + "\n",
                                                    attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
        text.scrollToEndOfDocument(nil)
    }
}
