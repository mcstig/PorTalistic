// Portalistic — the starting screen: starting up, waiting, or what went wrong.

import AppKit

/// What the window shows while the VM's screen isn't there: starting up, waiting, or stopped
/// (with a button to start it).
final class StartView: NSView {
    private let title = NSTextField(labelWithString: "Portalistic")
    private let status = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    let button = NSButton(title: "Start", target: nil, action: nil)
    let logButton = NSButton(title: "Show Log", target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        title.font = .systemFont(ofSize: 30, weight: .semibold)
        title.textColor = .white
        status.font = .systemFont(ofSize: 15)
        status.textColor = .secondaryLabelColor
        status.alignment = .center
        status.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .tertiaryLabelColor
        detail.alignment = .center
        detail.maximumNumberOfLines = 3
        detail.preferredMaxLayoutWidth = 640
        spinner.style = .spinning
        spinner.isDisplayedWhenStopped = false
        button.bezelStyle = .rounded
        button.controlSize = .large
        logButton.bezelStyle = .rounded
        logButton.controlSize = .large
        let buttons = NSStackView(views: [logButton, button])
        buttons.orientation = .horizontal
        buttons.spacing = 12
        let stack = NSStackView(views: [title, spinner, status, detail, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.setCustomSpacing(22, after: title)
        stack.setCustomSpacing(20, after: detail)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -80),
            status.widthAnchor.constraint(lessThanOrEqualToConstant: 640),
            detail.widthAnchor.constraint(lessThanOrEqualToConstant: 640),
        ])
        show("", busy: true)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// busy: the spinner turns; button: the main button's title (nil: none); log: Show Log too.
    func show(_ text: String, detail more: String = "", busy: Bool, button title: String? = nil, log: Bool = false) {
        status.stringValue = text
        setDetail(more)
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        spinner.isHidden = !busy
        button.isHidden = title == nil
        if let t = title { button.title = t }
        logButton.isHidden = !log
    }

    func setDetail(_ text: String) {
        detail.stringValue = text
        detail.isHidden = text.isEmpty
    }
}
