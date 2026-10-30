// Portalistic — the Activity window: the Steam menu's longer jobs (update, restarting Steam,
// saving logs, shutting down) as a list of steps, not a terminal.

import AppKit

/// The Steam menu's longer jobs as they run: a heading with a spinner, one row per step (the
/// bottle command's "==>" lines) with a tick once the next step starts, the latest plain line of
/// output under the current step, and a "Details" disclosure with the whole output for whoever
/// needs it (Oct 22: it used to be the raw terminal output only, which looked like one).
final class ActivityWindow: NSWindowController {
    private let heading = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let steps = NSStackView()
    private let stepsScroll = NSScrollView()
    private let text: NSTextView
    private let detailsScroll: NSScrollView
    private let detailsButton = NSButton(title: "Details", target: nil, action: nil)
    private let doneButton = NSButton(title: "Close", target: nil, action: nil)
    private(set) var command: BottleCommand?
    private let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    private var rows: [StepRow] = []
    private var current: StepRow?
    private var stepHeight: NSLayoutConstraint?
    private var detailsHeight: NSLayoutConstraint?

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "Portalistic Activity"
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 440, height: 260)
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.isEditable = false
        tv.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.textContainerInset = NSSize(width: 6, height: 6)
        text = tv
        detailsScroll = scroll
        super.init(window: w)

        heading.font = .systemFont(ofSize: 17, weight: .semibold)
        heading.lineBreakMode = .byTruncatingTail
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isDisplayedWhenStopped = false
        let top = NSStackView(views: [spinner, heading])
        top.orientation = .horizontal
        top.alignment = .centerY
        top.spacing = 10

        steps.orientation = .vertical
        steps.alignment = .leading
        steps.spacing = 2
        steps.edgeInsets = NSEdgeInsets(top: 2, left: 0, bottom: 2, right: 0)
        let flipped = FlippedClipView()
        stepsScroll.contentView = flipped
        stepsScroll.documentView = steps
        stepsScroll.hasVerticalScroller = true
        stepsScroll.drawsBackground = false
        stepsScroll.borderType = .noBorder
        steps.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            steps.leadingAnchor.constraint(equalTo: flipped.leadingAnchor),
            steps.trailingAnchor.constraint(equalTo: flipped.trailingAnchor),
            steps.topAnchor.constraint(equalTo: flipped.topAnchor),
        ])

        detailsButton.bezelStyle = .inline
        detailsButton.setButtonType(.pushOnPushOff)
        detailsButton.controlSize = .small
        detailsButton.target = self
        detailsButton.action = #selector(toggleDetails(_:))
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"
        doneButton.target = self
        doneButton.action = #selector(closeWindow(_:))
        doneButton.isHidden = true
        let spacer = NSView()
        let bar = NSStackView(views: [detailsButton, spacer, doneButton])
        bar.orientation = .horizontal
        bar.alignment = .centerY
        bar.spacing = 8
        detailsScroll.isHidden = true
        detailsScroll.borderType = .bezelBorder

        let content = NSView()
        for v in [top, stepsScroll, detailsScroll, bar] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        detailsHeight = detailsScroll.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            top.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            top.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -22),
            stepsScroll.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 14),
            stepsScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            stepsScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            detailsScroll.topAnchor.constraint(equalTo: stepsScroll.bottomAnchor, constant: 8),
            detailsScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            detailsScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            detailsHeight!,
            bar.topAnchor.constraint(equalTo: detailsScroll.bottomAnchor, constant: 10),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 8),
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
        rows.forEach { $0.removeFromSuperview() }
        rows = []
        current = nil
        heading.stringValue = title + "…"
        doneButton.isHidden = true
        spinner.isHidden = false
        spinner.startAnimation(nil)
        c.onLine = { [weak self] line in self?.took(line) }
        c.onExit = { [weak self, unowned c] code in
            guard let self = self else { return }
            self.spinner.stopAnimation(nil)
            self.spinner.isHidden = true
            self.current?.finish(ok: code == 0)
            self.heading.stringValue = code == 0 ? title + ": done" : title + ": didn't work"
            if code != 0 { self.showDetails(true) }
            self.doneButton.isHidden = false
            then?(code, c)
            self.onFinish?()
        }
        command = c
        window?.title = title
        showWindow(nil)
        if !c.start() {
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            heading.stringValue = "Couldn't run Portalistic's helper script (\(BottleCommand.script ?? "no kit folder"))."
            doneButton.isHidden = false
        }
    }

    private func took(_ line: String) {
        append(line)
        let plain = line.trimmingCharacters(in: .whitespaces)
        if plain.hasPrefix("==> ") {
            current?.finish(ok: true)
            current = addRow(StepRow(readableLine(plain)))
        } else if plain.hasPrefix("== ") {
            // a heading of plain output (bottle library folders, status): a row without a mark
            current?.finish(ok: true)
            current = nil
            addRow(StepRow(String(plain.dropFirst(3)), kind: .heading))
        } else if plain.hasPrefix("warn:") || plain.hasPrefix("error:") {
            if let cur = current { cur.note(readableLine(plain), problem: true) } else { addRow(StepRow(readableLine(plain), kind: .problem)) }
        } else if !plain.isEmpty, !plain.hasPrefix("time=") {
            if let cur = current {
                cur.note(readableLine(plain), problem: false)
            } else {
                addRow(StepRow(line.trimmingCharacters(in: .newlines), kind: .text))   // (plain output, as it is)
            }
        }
    }

    @discardableResult
    private func addRow(_ row: StepRow) -> StepRow {
        steps.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: steps.widthAnchor).isActive = true
        rows.append(row)
        steps.layoutSubtreeIfNeeded()
        if let doc = stepsScroll.documentView { doc.scroll(NSPoint(x: 0, y: max(0, doc.bounds.height - stepsScroll.contentSize.height))) }
        return row
    }

    private func append(_ line: String) {
        text.textStorage?.append(NSAttributedString(string: line + "\n",
                                                    attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
        if !detailsScroll.isHidden { text.scrollToEndOfDocument(nil) }
    }

    @objc private func toggleDetails(_ sender: Any?) { showDetails(detailsScroll.isHidden) }
    @objc private func closeWindow(_ sender: Any?) { window?.close() }

    private func showDetails(_ on: Bool) {
        detailsScroll.isHidden = !on
        detailsHeight?.constant = on ? 150 : 0
        detailsButton.state = on ? .on : .off
        if on { text.scrollToEndOfDocument(nil) }
    }
}

/// A clip view whose content starts at the top.
private final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}

/// One step: a mark (spinner while it runs, a tick or a cross after), its title, and its latest line.
final class StepRow: NSView {
    enum Kind { case step, heading, text, problem }
    private let mark = NSImageView()
    private let busy = NSProgressIndicator()
    private let title = NSTextField(wrappingLabelWithString: "")
    private let note = NSTextField(wrappingLabelWithString: "")

    init(_ text: String, kind: Kind = .step) {
        super.init(frame: .zero)
        title.stringValue = text
        title.font = .systemFont(ofSize: 13)
        title.maximumNumberOfLines = 2
        switch kind {
        case .step: break
        case .heading:
            title.font = .systemFont(ofSize: 13, weight: .semibold)
        case .text:
            title.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            title.maximumNumberOfLines = 4
            title.textColor = .secondaryLabelColor
        case .problem:
            title.textColor = .systemOrange
        }
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.maximumNumberOfLines = 2
        note.isHidden = true
        busy.style = .spinning
        busy.controlSize = .small
        busy.isDisplayedWhenStopped = false
        if kind == .step { busy.startAnimation(nil) }
        mark.imageScaling = .scaleProportionallyUpOrDown
        mark.isHidden = true
        let marks = NSView()
        for v in [mark, busy] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            marks.addSubview(v)
            NSLayoutConstraint.activate([v.centerXAnchor.constraint(equalTo: marks.centerXAnchor),
                                         v.centerYAnchor.constraint(equalTo: marks.centerYAnchor),
                                         v.widthAnchor.constraint(equalToConstant: 16), v.heightAnchor.constraint(equalToConstant: 16)])
        }
        let column = NSStackView(views: [title, note])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 1
        let row = NSStackView(views: [marks, column])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 4, left: 2, bottom: 4, right: 2)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            marks.widthAnchor.constraint(equalToConstant: 20), marks.heightAnchor.constraint(equalToConstant: 18),
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func note(_ text: String, problem: Bool) {
        note.stringValue = text
        note.textColor = problem ? .systemOrange : .secondaryLabelColor
        note.isHidden = text.isEmpty
    }

    func finish(ok: Bool) {
        busy.stopAnimation(nil)
        mark.image = NSImage(systemSymbolName: ok ? "checkmark.circle.fill" : "xmark.circle.fill", accessibilityDescription: nil)
        mark.contentTintColor = ok ? .systemGreen : .systemRed
        mark.isHidden = false
        if ok && note.textColor != .systemOrange { note.isHidden = true }
    }
}
