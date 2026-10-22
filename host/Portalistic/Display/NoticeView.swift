// Portalistic — a notice over the picture: something the VM wants the player to read (why a
// game closed at launch, say). A banner at the top of the window that goes away by itself after
// a while, or when clicked; a notice can also do something when it's clicked (show(onClick:)).

import AppKit

final class NoticeView: NSView {
    private let title = NSTextField(wrappingLabelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let icon = NSImageView()
    private var hideAt: Date = .distantPast
    private var hideTimer: Timer?
    private var onClick: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.92).cgColor
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 1, alpha: 0.12).cgColor
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.textColor = .white
        title.maximumNumberOfLines = 2
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = NSColor(white: 0.82, alpha: 1)
        detail.maximumNumberOfLines = 6
        title.preferredMaxLayoutWidth = 560
        detail.preferredMaxLayoutWidth = 560
        icon.imageScaling = .scaleProportionallyUpOrDown
        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 4
        let row = NSStackView(views: [icon, text])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 16)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),
            title.widthAnchor.constraint(lessThanOrEqualToConstant: 560),
            detail.widthAnchor.constraint(lessThanOrEqualToConstant: 560),
        ])
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func mouseDown(with event: NSEvent) {
        let action = onClick
        dismiss()
        action?()
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Shows the notice for `seconds` (a newer one replaces it); onClick runs if it's clicked.
    func show(problem: Bool, title t: String, detail d: String, seconds: Double, onClick: (() -> Void)? = nil) {
        self.onClick = onClick
        title.stringValue = t
        detail.stringValue = d
        detail.isHidden = d.isEmpty
        icon.image = NSImage(systemSymbolName: problem ? "exclamationmark.triangle.fill" : "info.circle.fill",
                             accessibilityDescription: nil)
        icon.contentTintColor = problem ? .systemYellow : .systemBlue
        place()
        alphaValue = 0
        isHidden = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            self.animator().alphaValue = 1
        }
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(timeInterval: seconds, target: self, selector: #selector(timerFired),
                                         userInfo: nil, repeats: false)
    }

    @objc private func timerFired() { dismiss() }

    func dismiss() {
        onClick = nil
        hideTimer?.invalidate()
        hideTimer = nil
        guard !isHidden else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.isHidden = true
        })
    }

    /// At the top middle of the window, below the title bar, at its text's size.
    func place() {
        guard let parent = superview else { return }
        layoutSubtreeIfNeeded()
        let size = fittingSize
        let w = min(size.width, parent.bounds.width - 40), h = size.height
        frame = NSRect(x: ((parent.bounds.width - w) / 2).rounded(), y: (parent.bounds.height - h - 44).rounded(),
                       width: w, height: h)
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]   // stays at the top middle
    }
}

/// A card in the middle of the window while the VM gets Steam ready (an update of the Linux
/// system, games moving into a drive, Steam's own start): a spinner, what is happening, and a
/// line of detail. bottle-splash in the VM sends it (notice kind 2); the next kind-2 notice
/// replaces the text, an empty one takes the card down. Nothing to click.
final class ProgressCard: NSView {
    private let heading = NSTextField(labelWithString: "Portalistic")
    private let text = NSTextField(wrappingLabelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private var lastShown: Date = .distantPast

    override init(frame: NSRect) {
        super.init(frame: frame)
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.10, alpha: 0.94).cgColor
        layer?.cornerRadius = 16
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 1, alpha: 0.14).cgColor
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        heading.textColor = NSColor(white: 0.70, alpha: 1)
        text.font = .systemFont(ofSize: 16, weight: .medium)
        text.textColor = .white
        text.maximumNumberOfLines = 3
        text.preferredMaxLayoutWidth = 420
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = NSColor(white: 0.72, alpha: 1)
        detail.maximumNumberOfLines = 3
        detail.preferredMaxLayoutWidth = 420
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isDisplayedWhenStopped = false
        let column = NSStackView(views: [heading, text, detail])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 5
        let row = NSStackView(views: [spinner, column])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 16
        row.edgeInsets = NSEdgeInsets(top: 18, left: 22, bottom: 18, right: 26)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            text.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            detail.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The card with this text (empty: the card goes away).
    func show(text t: String, detail d: String) {
        if t.isEmpty { dismiss(); return }
        text.stringValue = t
        detail.stringValue = d
        detail.isHidden = d.isEmpty
        place()
        if isHidden {
            alphaValue = 0
            isHidden = false
            spinner.startAnimation(nil)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                self.animator().alphaValue = 1
            }
        }
        lastShown = Date()
    }

    func dismiss() {
        guard !isHidden else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.isHidden = true
            self?.spinner.stopAnimation(nil)
        })
    }

    /// In the middle of the window, at its text's size.
    func place() {
        guard let parent = superview else { return }
        layoutSubtreeIfNeeded()
        let size = fittingSize
        let w = min(max(size.width, 360), parent.bounds.width - 40), h = size.height
        frame = NSRect(x: ((parent.bounds.width - w) / 2).rounded(), y: ((parent.bounds.height - h) / 2).rounded(),
                       width: w, height: h)
    }
}
