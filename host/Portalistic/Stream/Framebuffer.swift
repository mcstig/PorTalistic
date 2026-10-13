// Portalistic — the VM's screen as one picture, and the stream's counters.

import AppKit
import CoreGraphics

/// The VM's screen as the app has it: every frame (the whole screen, or just the part that
/// changed) drawn into one bitmap, BGRX like Metal's bgra8Unorm, and the part that changed since
/// the display last took it. Written by the network thread, read by the main thread.
final class Framebuffer {
    let width: Int, height: Int, stride: Int
    let data: UnsafeMutableRawPointer
    let lock = NSLock()
    var dirty = CGRect.null          // pixels, top-left origin (with lock)
    private var ctx: CGContext?      // made with the first piece's colour space: no conversion per frame

    init?(width: Int, height: Int) {
        guard width > 0, height > 0 else { return nil }
        self.width = width
        self.height = height
        stride = width * 4
        data = UnsafeMutableRawPointer.allocate(byteCount: stride * height, alignment: 64)
        data.initializeMemory(as: UInt8.self, repeating: 0, count: stride * height)
    }

    deinit { data.deallocate() }

    private func context(for img: CGImage) -> CGContext? {
        if let c = ctx { return c }
        var space = img.colorSpace
        if space?.model != .rgb { space = CGColorSpace(name: CGColorSpace.sRGB) }
        let info = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let sp = space, let c = CGContext(data: data, width: width, height: height, bitsPerComponent: 8,
                                                bytesPerRow: stride, space: sp, bitmapInfo: info) else { return nil }
        c.interpolationQuality = .none
        c.setBlendMode(.copy)
        ctx = c
        return c
    }

    /// A decoded piece at x, y (top-left origin). Network thread.
    func draw(_ img: CGImage, x: Int, y: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard let c = context(for: img) else { return }
        // Quartz's origin is bottom-left; the bitmap's first row is the top one.
        c.draw(img, in: CGRect(x: x, y: height - y - img.height, width: img.width, height: img.height))
        dirty = dirty.union(CGRect(x: x, y: y, width: img.width, height: img.height))
    }

    /// The whole picture as an image (for the display without Metal).
    func image() -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        dirty = .null
        return ctx?.makeImage()
    }
}

/// Counters for View > Show Stream Info.
struct StreamStats {
    var frames = 0, bytes = 0                  // received since the last look
    var decodeMs = 0.0, drawMs = 0.0           // per frame: JPEG decode (in parallel), into the picture
    var serverFPS = 0.0, captureMs = 0.0, encodeMs = 0.0, sendMs = 0.0, serverBytes = 0, sharp = 0
    var haveServer = false
}
