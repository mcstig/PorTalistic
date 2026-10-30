// Portalistic — a notice over the picture: something the VM wants the player to read (why a
// game closed at launch, say). A banner at the top of the window that goes away by itself after
// a while, or when clicked; a notice can also do something when it's clicked (show(onClick:)).

import AppKit

/// The notice's detail text: a click on it counts as a click on the banner (it's not selectable).
final class NoticeText: NSTextView {
    override func mouseDown(with event: NSEvent) {
        if let banner = enclosingScrollView?.superview?.superview?.superview as? NoticeView { banner.mouseDown(with: event) }
    }
}

final class NoticeView: NSView {
    private let title = NSTextField(wrappingLabelWithString: "")
    // (Oct 26) the detail scrolls when it's long: a fixes-list note under the diagnosis ran under the buttons
    private let detail = NoticeText()
    private let detailScroll = NSScrollView()
    private var detailHeight: NSLayoutConstraint!
    private var detailScrollWidth: NSLayoutConstraint!
    private static let detailWidth: CGFloat = 560
    private static let detailMaxHeight: CGFloat = 132   // about 8 lines
    private let icon = NSImageView()
    private var hideAt: Date = .distantPast
    private var hideTimer: Timer?
    private var onClick: (() -> Void)?
    private let buttons = NSStackView()           // (Oct 26) buttons under the text: "Install it and try again", "Report this…"
    private var actions: [() -> Void] = []

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
        detail.isEditable = false
        detail.isSelectable = false
        detail.drawsBackground = false
        detail.textContainerInset = .zero
        detail.textContainer?.lineFragmentPadding = 0
        detail.textContainer?.widthTracksTextView = false
        detail.textContainer?.containerSize = NSSize(width: NoticeView.detailWidth - 16, height: .greatestFiniteMagnitude)   // (room for the scroller)
        detail.isVerticallyResizable = false
        detail.isHorizontallyResizable = false
        detail.frame = NSRect(x: 0, y: 0, width: NoticeView.detailWidth, height: 20)
        detailScroll.documentView = detail
        detailScroll.drawsBackground = false
        detailScroll.hasVerticalScroller = true
        detailScroll.autohidesScrollers = true
        detailScroll.scrollerStyle = .overlay
        detailScroll.verticalScrollElasticity = .none
        detailHeight = detailScroll.heightAnchor.constraint(equalToConstant: 20)
        // (wants 560; gives way in a narrow window instead of breaking the layout: Oct 27 log)
        detailScrollWidth = detailScroll.widthAnchor.constraint(equalToConstant: NoticeView.detailWidth)
        detailScrollWidth.priority = .defaultHigh
        title.preferredMaxLayoutWidth = NoticeView.detailWidth
        icon.imageScaling = .scaleProportionallyUpOrDown
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.isHidden = true
        let text = NSStackView(views: [title, detailScroll, buttons])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 4
        text.setCustomSpacing(10, after: detailScroll)
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
            title.widthAnchor.constraint(lessThanOrEqualToConstant: NoticeView.detailWidth),
            detailScrollWidth,
            detailHeight,
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
    /// `choices`: (label, action) pairs shown as buttons; a notice with buttons stays until one is
    /// pressed or the banner is clicked away (its timer is at least 2 minutes).
    func show(problem: Bool, title t: String, detail d: String, seconds: Double, onClick: (() -> Void)? = nil,
              choices: [(String, () -> Void)] = []) {
        self.onClick = onClick
        title.stringValue = t
        setDetail(d)
        buttons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        actions = choices.map { $0.1 }
        for (i, c) in choices.enumerated() {
            let b = NSButton(title: c.0, target: self, action: #selector(choicePressed(_:)))
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.tag = i
            if i == 0 { b.keyEquivalent = "\r" }
            buttons.addArrangedSubview(b)
        }
        buttons.isHidden = choices.isEmpty
        let seconds = choices.isEmpty ? seconds : max(seconds, 120)
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

    /// The detail text, its box as tall as the text up to about 8 lines (then it scrolls).
    private func setDetail(_ d: String) {
        detail.string = d
        detail.textColor = NSColor(white: 0.82, alpha: 1)
        detail.font = .systemFont(ofSize: 12)
        detailScroll.isHidden = d.isEmpty
        guard !d.isEmpty else { detailHeight.constant = 0; return }
        let bounds = (d as NSString).boundingRect(with: NSSize(width: NoticeView.detailWidth - 16, height: 10000),
                                                  options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                  attributes: [.font: NSFont.systemFont(ofSize: 12)])
        let h = ceil(bounds.height) + 2
        detail.frame = NSRect(x: 0, y: 0, width: NoticeView.detailWidth, height: h)
        detailHeight.constant = min(h, NoticeView.detailMaxHeight)
        detail.scroll(.zero)
    }

    @objc private func timerFired() { dismiss() }

    @objc private func choicePressed(_ sender: NSButton) {
        // (take the action before dismiss() clears the list: Oct 26, the Report button did nothing)
        let action = sender.tag < actions.count ? actions[sender.tag] : nil
        dismiss()
        action?()
    }

    func dismiss() {
        onClick = nil
        actions = []
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
