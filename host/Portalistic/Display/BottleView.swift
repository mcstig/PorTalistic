// Portalistic — the view that shows the VM's screen and sends it keyboard and mouse,
// with mouse capture for games that hide the pointer.

import AppKit
import CoreGraphics
import QuartzCore

final class BottleView: NSView {
    let conn: Connection
    var screenW = 1920, screenH = 1080
    var connected = false { didSet { refreshCapture() } }
    var covered = false { didSet { refreshCapture() } }   // the starting screen is over the picture
    private(set) var captured = false
    var autoCapture = true                      // false after Command-Escape, until the next click
    var remoteCursorVisible = true
    var onCaptureChange: ((Bool) -> Void)?

    private let imageLayer = CALayer()          // the display without Metal
    let renderer = Renderer()
    private let infoLayer = CATextLayer()       // View > Show Stream Info
    private(set) var lastFrame: Framebuffer?
    private(set) var shown = 0                  // frames drawn (Stream Info counts them)
    private var keysDown = Set<UInt16>()
    private var accX: CGFloat = 0, accY: CGFloat = 0
    private var scrollX: CGFloat = 0, scrollY: CGFloat = 0
    private var tracking: NSTrackingArea?
    private var skipMotion = false              // the first event after capturing can carry the pointer warp

    init(conn: Connection) {
        self.conn = conn
        super.init(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
        let root = CALayer()
        root.frame = bounds          // sublayers below are laid out for this size, then autoresize
        root.backgroundColor = NSColor.black.cgColor
        layer = root
        wantsLayer = true
        imageLayer.frame = root.bounds
        imageLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]   // follows the window
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.minificationFilter = .linear
        imageLayer.magnificationFilter = .linear
        root.addSublayer(imageLayer)
        if let r = renderer {
            r.layer.frame = root.bounds          // sizeRenderer keeps it the view's size
            root.addSublayer(r.layer)
        }
        infoLayer.fontSize = 12
        infoLayer.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        infoLayer.foregroundColor = NSColor.white.cgColor
        infoLayer.backgroundColor = NSColor(white: 0, alpha: 0.6).cgColor
        infoLayer.cornerRadius = 6
        infoLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        infoLayer.isHidden = true
        infoLayer.autoresizingMask = [.layerMinYMargin, .layerMaxXMargin]   // stays at the top left
        root.addSublayer(infoLayer)
    }

    /// The picture changed (or the window did): draw it. Not while the window can't be seen
    /// (minimized, covered, another Space): Metal would wait for the display there; the changed
    /// part keeps adding up and is drawn when the window shows again (redraw()).
    func show(_ fb: Framebuffer) {
        lastFrame = fb
        if let w = window, !w.occlusionState.contains(.visible) { return }
        if let r = renderer {
            if r.onReady == nil { r.onReady = { [weak self] in self?.redraw() } }
            r.draw(fb, picture: picturePixels(), live: inLiveResize)
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            imageLayer.contents = fb.image()
            CATransaction.commit()
        }
        shown += 1
    }

    func redraw() { if let fb = lastFrame { show(fb) } }

    /// The picture's rectangle in the Metal layer's pixels (top-left origin).
    private func picturePixels() -> CGRect {
        let r = pictureRect(), scale = renderer?.layer.contentsScale ?? 2
        let x = (r.minX * scale).rounded(), y = ((bounds.height - r.maxY) * scale).rounded()
        return CGRect(x: x, y: y, width: (r.width * scale).rounded(), height: (r.height * scale).rounded())
    }

    /// The Metal layer's drawable follows the view's size and the screen's pixel density.
    private func sizeRenderer() {
        guard let r = renderer else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        r.layer.frame = bounds
        r.layer.contentsScale = scale
        r.layer.drawableSize = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        infoLayer.contentsScale = scale
        CATransaction.commit()
        redraw()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        sizeRenderer()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        redraw()                                 // now with MetalFX at the final size
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        sizeRenderer()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        sizeRenderer()
    }

    /// View > Show Stream Info: nil hides it.
    func setInfo(_ text: String?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let t = text {
            infoLayer.string = t
            let rows = t.split(separator: "\n")
            let lines = CGFloat(rows.count), longest = CGFloat(rows.map { $0.count }.max() ?? 0)
            let size = CGSize(width: longest * 7.3 + 16, height: lines * 15 + 10)   // 12 pt monospaced
            infoLayer.frame = CGRect(x: 10, y: bounds.height - 10 - size.height, width: size.width, height: size.height)
            infoLayer.isHidden = false
        } else {
            infoLayer.isHidden = true
        }
        CATransaction.commit()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isOpaque: Bool { true }



    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    /// The picture's rectangle inside the view (aspect fit, letterboxed).
    func pictureRect() -> CGRect {
        let b = bounds
        let sw = CGFloat(screenW), sh = CGFloat(screenH)
        guard sw > 0, sh > 0 else { return b }
        let s = min(b.width / sw, b.height / sh)
        let w = sw * s, h = sh * s
        return CGRect(x: (b.width - w) / 2, y: (b.height - h) / 2, width: w, height: h)
    }

    private func remotePoint(_ e: NSEvent) -> (Int, Int)? {
        let p = convert(e.locationInWindow, from: nil)
        let r = pictureRect()
        guard r.width > 0, r.height > 0 else { return nil }
        let x = (p.x - r.minX) / r.width * CGFloat(screenW)
        let y = (r.maxY - p.y) / r.height * CGFloat(screenH)
        return (Int(min(max(x, 0), CGFloat(screenW - 1))), Int(min(max(y, 0), CGFloat(screenH - 1))))
    }

    // MARK: mouse capture

    /// Capture while the game hides its pointer, the window has focus and the user hasn't
    /// released the mouse with Command-Escape.
    func refreshCapture() {
        let focused = (window?.isKeyWindow ?? false) && NSApp.isActive
        setCaptured(connected && !covered && focused && autoCapture && !remoteCursorVisible)
    }

    private var pointerBeforeCapture: CGPoint?   // where the Mac pointer was (CG coordinates), put back on release

    private func setCaptured(_ on: Bool) {
        guard on != captured else { return }
        captured = on
        accX = 0; accY = 0
        skipMotion = on
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        if on {
            // Park the Mac pointer over the middle of the picture, then freeze it there; it goes
            // back to where it was when the mouse is released (Oct 22: it used to reappear in the
            // middle of the window every time, which Michael found annoying).
            let m = NSEvent.mouseLocation
            pointerBeforeCapture = CGPoint(x: m.x, y: primaryHeight - m.y)
            if let w = window {
                let r = w.convertToScreen(convert(pictureRect(), to: nil))
                CGWarpMouseCursorPosition(CGPoint(x: r.midX, y: primaryHeight - r.midY))
            }
            _ = CGAssociateMouseAndMouseCursorPosition(0)
            NSCursor.hide()
        } else {
            _ = CGAssociateMouseAndMouseCursorPosition(1)
            if let p = pointerBeforeCapture {
                CGWarpMouseCursorPosition(p)
                pointerBeforeCapture = nil
            }
            NSCursor.unhide()
        }
        onCaptureChange?(on)
    }

    func releaseMouse() {
        autoCapture = false
        refreshCapture()
    }

    /// Focus went elsewhere: let go of the mouse and of every key and button.
    func focusLost() {
        refreshCapture()
        keysDown.removeAll()
        conn.send(ClientMsg.release, [])
    }

    // MARK: mouse events

    private func motion(_ e: NSEvent) {
        if captured {
            if skipMotion { skipMotion = false; return }
            accX += e.deltaX
            accY += e.deltaY
            let dx = Int(accX.rounded(.towardZero)), dy = Int(accY.rounded(.towardZero))
            if dx != 0 || dy != 0 {
                accX -= CGFloat(dx); accY -= CGFloat(dy)
                conn.send(ClientMsg.moveRel, le16(dx) + le16(dy))
            }
        } else if let p = remotePoint(e) {
            conn.send(ClientMsg.moveAbs, le16(p.0) + le16(p.1))
        }
    }

    private func button(_ b: UInt8, _ down: Bool) { conn.send(ClientMsg.button, [b, down ? 1 : 0]) }

    private func otherButton(_ e: NSEvent) -> UInt8 {
        switch e.buttonNumber {
        case 3: return 8      // back
        case 4: return 9      // forward
        default: return 2     // middle
        }
    }

    override func mouseMoved(with e: NSEvent) { motion(e) }
    override func mouseDragged(with e: NSEvent) { motion(e) }
    override func rightMouseDragged(with e: NSEvent) { motion(e) }
    override func otherMouseDragged(with e: NSEvent) { motion(e) }

    override func mouseDown(with e: NSEvent) {
        if !autoCapture { autoCapture = true; refreshCapture() }
        motion(e)
        button(1, true)
    }
    override func mouseUp(with e: NSEvent) { button(1, false) }
    override func rightMouseDown(with e: NSEvent) { motion(e); button(3, true) }
    override func rightMouseUp(with e: NSEvent) { button(3, false) }
    override func otherMouseDown(with e: NSEvent) { motion(e); button(otherButton(e), true) }
    override func otherMouseUp(with e: NSEvent) { button(otherButton(e), false) }

    override func scrollWheel(with e: NSEvent) {
        var dx = e.scrollingDeltaX, dy = e.scrollingDeltaY
        if e.hasPreciseScrollingDeltas { dx /= 12; dy /= 12 }        // trackpad: points, not notches
        scrollX += dx; scrollY += dy
        let nx = Int(scrollX.rounded(.towardZero)), ny = Int(scrollY.rounded(.towardZero))
        if nx != 0 || ny != 0 {
            scrollX -= CGFloat(nx); scrollY -= CGFloat(ny)
            conn.send(ClientMsg.wheel, le16(-nx) + le16(ny))          // protocol: dx > 0 = right, dy > 0 = up
        }
    }

    // MARK: keyboard

    private func key(_ code: UInt16, _ down: Bool) {
        guard let ks = keysyms[code] else { return }
        if down { keysDown.insert(code) } else { keysDown.remove(code) }
        conn.send(ClientMsg.key, le32(ks) + [down ? 1 : 0])
    }

    override func keyDown(with e: NSEvent) {
        if e.modifierFlags.contains(.command) { return }   // Command shortcuts stay with the Mac
        if e.isARepeat { return }                          // the game sees the key held down
        key(e.keyCode, true)
    }

    override func keyUp(with e: NSEvent) {
        if keysDown.contains(e.keyCode) { key(e.keyCode, false) }
    }

    override func flagsChanged(with e: NSEvent) {
        let code = e.keyCode
        if code == 0x39 {                                  // Caps Lock: one event per toggle
            key(code, true); key(code, false)
            return
        }
        guard let bit = modifierBits[code] else { return } // Command and Fn aren't sent
        let down = (e.modifierFlags.rawValue & bit) != 0
        if down != keysDown.contains(code) { key(code, down) }
    }

    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        // Control-key combinations are game keys, not menu shortcuts.
        if !e.modifierFlags.contains(.command) && window?.firstResponder === self {
            if e.type == .keyDown { keyDown(with: e) }
            return true
        }
        return super.performKeyEquivalent(with: e)
    }
}
