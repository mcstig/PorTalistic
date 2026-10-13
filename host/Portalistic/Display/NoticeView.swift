// Portalistic — a notice over the picture: something the VM wants the player to read (why a
// game closed at launch, say). A banner at the top of the window that goes away by itself after
// a while, or when clicked.

import AppKit

final class NoticeView: NSView {
    private let title = NSTextField(wrappingLabelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let icon = NSImageView()
    private var hideAt: Date = .distantPast
    private var hideTimer: Timer?

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

    override func mouseDown(with event: NSEvent) { dismiss() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Shows the notice for `seconds` (a newer one replaces it).
    func show(problem: Bool, title t: String, detail d: String, seconds: Double) {
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
