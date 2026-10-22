// Portalistic — the connection to the VM's screen server (127.0.0.1:4720, forwarded by
// Lima): reads frames and decodes them three at a time, sends input.

import AppKit
import CoreGraphics
import Darwin
import ImageIO
import QuartzCore

final class Connection {
    var onConnected: ((Bool) -> Void)?           // main thread
    var onSize: ((Int, Int) -> Void)?            // main thread
    var onFrame: ((Framebuffer) -> Void)?       // main thread, after one or more frames arrived
    var onCursor: ((Bool) -> Void)?              // main thread
    var onRumble: ((Int, Float, Float, Double) -> Void)?   // main thread: pad, strong, weak, seconds (0 = stop)
    var onPadStatus: ((Bool) -> Void)?           // main thread: false = the VM can't create controllers
    var onNotice: ((Int, String, String, Double) -> Void)?   // main thread: kind (0 news, 1 problem, 2 progress), title, details, seconds
    /// The screen server's protocol version (2: RESIZE, NOTICE, HOST_STATS); 0 while not connected.
    private(set) var serverVersion = 0           // main thread

    private var fd: Int32 = -1                   // owned by sendQueue
    private let sendQueue = DispatchQueue(label: "bottle.send")
    private let frameLock = NSLock()
    private var frameScheduled = false
    private var latest: Framebuffer?             // with frameLock: what the main thread shows next
    // Frames are decoded several at a time (one JPEG takes ~10 ms, too slow for 120 fps on one
    // thread), then drawn into the picture strictly in the order they came: a partial frame
    // only makes sense on top of the one before it.
    private struct Piece { let img: CGImage?; let x, y, sw, sh, bytes: Int; let ms: Double }
    private let decodeQueue = DispatchQueue(label: "bottle.decode", qos: .userInteractive, attributes: .concurrent)
    private let decodeSlots = DispatchSemaphore(value: 3)   // frames decoding at once
    private var nextTicket = 0                   // network thread
    private let commitLock = NSLock()
    private var nextCommit = 0                   // with commitLock
    private var decoded: [Int: Piece] = [:]      // with commitLock: done, waiting for their turn
    private var fb: Framebuffer?                 // with commitLock
    private let statsLock = NSLock()
    private var stats = StreamStats()            // with statsLock
    private var fps: UInt8 = 60                  // with statsLock
    private var wantedSize: [UInt8]?             // with statsLock: the last RESIZE body, sent again on connect

    func start() { Thread.detachNewThread { self.run() } }

    /// The frame rate to ask the VM for (sent now if connected, and on every connect).
    func setFrameRate(_ v: UInt8) {
        statsLock.lock()
        fps = fixedFPS ?? v
        let f = fps
        statsLock.unlock()
        send(ClientMsg.settings, [jpegQuality, f, screenFeatures])
    }

    /// The screen size the window wants, and the size for games (0, 0: the window's). Sent now
    /// if connected, and again on every connect. Only to a screen server that knows RESIZE.
    func requestSize(width: Int, height: Int, gameWidth: Int, gameHeight: Int) {
        let body = le16(width) + le16(height) + le16(gameWidth) + le16(gameHeight)
        statsLock.lock()
        wantedSize = body
        statsLock.unlock()
        if serverVersion >= 2 { send(ClientMsg.resize, body) }
    }

    /// What arrived since the last call (and the VM's own numbers).
    func takeStats() -> StreamStats {
        statsLock.lock()
        defer { statsLock.unlock() }
        let s = stats
        stats.frames = 0
        stats.bytes = 0
        stats.decodeMs = 0
        stats.drawMs = 0
        return s
    }

    func send(_ type: UInt8, _ body: [UInt8]) {
        sendQueue.async {
            guard self.fd >= 0 else { return }
            var m = [UInt8](repeating: 0, count: 8)
            m[0] = type
            m.replaceSubrange(4..<8, with: le32(UInt32(body.count)))
            m += body
            m.withUnsafeBytes { raw in
                var off = 0
                while off < raw.count {
                    let k = Darwin.send(self.fd, raw.baseAddress! + off, raw.count - off, 0)
                    if k <= 0 { break }
                    off += k
                }
            }
        }
    }

    private func connectOnce() -> Int32 {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        if s < 0 { return -1 }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(screenPort).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc != 0 { close(s); return -1 }
        var one: Int32 = 1
        setsockopt(s, Int32(IPPROTO_TCP), TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        var big: Int32 = 4 << 20
        setsockopt(s, SOL_SOCKET, SO_RCVBUF, &big, socklen_t(MemoryLayout<Int32>.size))
        return s
    }

    private func readFully(_ s: Int32, _ buf: UnsafeMutableRawPointer, _ n: Int) -> Bool {
        var got = 0
        while got < n {
            let k = recv(s, buf + got, n - got, 0)
            if k <= 0 { return false }
            got += k
        }
        return true
    }

    private func run() {
        var cap = 1 << 20
        var payload = UnsafeMutableRawPointer.allocate(byteCount: cap, alignment: 8)
        let header = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        while true {
            let s = connectOnce()
            if s < 0 { sleep(1); continue }
            var connected = false
            while true {
                guard readFully(s, header, 8) else { break }
                let type = header.load(as: UInt8.self)
                let len = rd32(header, 4)
                if len > 64 << 20 { break }
                if len > cap {
                    payload.deallocate()
                    cap = len
                    payload = UnsafeMutableRawPointer.allocate(byteCount: cap, alignment: 8)
                }
                guard readFully(s, payload, len) else { break }
                switch type {
                case ServerMsg.hello:
                    guard len >= 16, payload.load(as: UInt8.self) == UInt8(ascii: "B") else { break }
                    let w = rd32(payload, 8), h = rd32(payload, 12)
                    let version = rd16(payload, 4)
                    connected = true
                    sendQueue.sync { self.fd = s }
                    statsLock.lock()
                    let f = fps, size = wantedSize
                    statsLock.unlock()
                    send(ClientMsg.settings, [jpegQuality, f, screenFeatures])
                    if version >= 2, let body = size { send(ClientMsg.resize, body) }
                    DispatchQueue.main.async {
                        self.serverVersion = version
                        self.onConnected?(true)
                        self.onSize?(w, h)
                    }
                case ServerMsg.notice:
                    guard len > 4 else { break }
                    let kind = Int(payload.load(as: UInt8.self))
                    let seconds = Double(max(3, rd16(payload, 2)))
                    let text = String(decoding: Data(bytes: payload + 4, count: len - 4), as: UTF8.self)
                    let lines = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                    let title = lines.first.map(String.init) ?? ""
                    let details = lines.count > 1 ? String(lines[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
                    DispatchQueue.main.async { self.onNotice?(kind, title, details, seconds) }
                case ServerMsg.frame:
                    // The JPEG is the whole screen, or (bottle-screen with partial frames) just
                    // the rectangle at x, y that changed: drawn into the picture either way.
                    guard len > 16 else { break }
                    let x = rd16(payload, 4), y = rd16(payload, 6)
                    let sw = rd16(payload, 12), sh = rd16(payload, 14)
                    let data = Data(bytes: payload + 16, count: len - 16)
                    let ticket = nextTicket
                    nextTicket += 1
                    decodeSlots.wait()           // all busy: stop reading (the VM then sends fewer)
                    decodeQueue.async {
                        let t0 = CACurrentMediaTime()
                        let opts = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
                        var img: CGImage?
                        if let src = CGImageSourceCreateWithData(data as CFData, nil) {
                            img = CGImageSourceCreateImageAtIndex(src, 0, opts)
                        }
                        self.commit(ticket, Piece(img: img, x: x, y: y, sw: sw, sh: sh, bytes: len,
                                                  ms: (CACurrentMediaTime() - t0) * 1000))
                        self.decodeSlots.signal()
                    }
                case ServerMsg.stats:
                    guard len >= 16 else { break }
                    statsLock.lock()
                    stats.haveServer = true
                    stats.serverFPS = Double(rd16(payload, 0)) / 10
                    stats.captureMs = Double(rd16(payload, 2)) / 100
                    stats.encodeMs = Double(rd16(payload, 4)) / 100
                    stats.sendMs = Double(rd16(payload, 6)) / 100
                    stats.serverBytes = rd32(payload, 8)
                    stats.sharp = rd16(payload, 12)
                    statsLock.unlock()
                case ServerMsg.cursor:
                    let visible = len >= 1 && payload.load(as: UInt8.self) != 0
                    DispatchQueue.main.async { self.onCursor?(visible) }
                case ServerMsg.rumble:
                    guard len >= 8 else { break }
                    let pad = Int(payload.load(as: UInt8.self))
                    let strong = Float(rd16(payload, 2)) / 65535, weak = Float(rd16(payload, 4)) / 65535
                    let ms = rd16(payload, 6)
                    let seconds = strong + weak == 0 ? 0 : (ms == 0 ? 60 : min(Double(ms) / 1000, 60))
                    DispatchQueue.main.async { self.onRumble?(pad, strong, weak, seconds) }
                case ServerMsg.padStatus:
                    guard len >= 2 else { break }
                    let ok = payload.load(fromByteOffset: 1, as: UInt8.self) != 0
                    DispatchQueue.main.async { self.onPadStatus?(ok) }
                default:
                    break
                }
            }
            sendQueue.sync { if self.fd == s { self.fd = -1 } }
            close(s)
            if connected { DispatchQueue.main.async { self.serverVersion = 0; self.onConnected?(false) } }
            sleep(1)
        }
    }

    /// A decoded frame: into the picture when its turn comes (with every later one already done).
    private func commit(_ ticket: Int, _ piece: Piece) {
        commitLock.lock()
        defer { commitLock.unlock() }
        decoded[ticket] = piece
        while let p = decoded.removeValue(forKey: nextCommit) {
            nextCommit += 1
            if fb == nil || fb?.width != p.sw || fb?.height != p.sh { fb = Framebuffer(width: p.sw, height: p.sh) }
            guard let f = fb, let img = p.img else { continue }
            let t0 = CACurrentMediaTime()
            f.draw(img, x: p.x, y: p.y)
            statsLock.lock()
            stats.frames += 1
            stats.bytes += p.bytes
            stats.decodeMs += p.ms
            stats.drawMs += (CACurrentMediaTime() - t0) * 1000
            statsLock.unlock()
            deliver(f)
        }
    }

    /// Tells the main thread the picture changed. Frames that arrive while it's still busy
    /// just add to the picture's changed part: one look at the picture covers them all.
    private func deliver(_ f: Framebuffer) {
        frameLock.lock()
        latest = f                               // a new size replaces the old picture
        let schedule = !frameScheduled
        frameScheduled = true
        frameLock.unlock()
        guard schedule else { return }
        DispatchQueue.main.async {
            self.frameLock.lock()
            self.frameScheduled = false
            let f = self.latest
            self.frameLock.unlock()
            guard let f = f else { return }
            self.onSize?(f.width, f.height)
            self.onFrame?(f)
        }
    }
}
