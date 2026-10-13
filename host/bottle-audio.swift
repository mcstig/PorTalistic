// bottle-audio: plays the SteamOS bottle's sound on the Mac.
//
// Inside the VM, PipeWire sends whatever games play (its "bottle-sink" output) as raw
// 48 kHz stereo 16-bit PCM to whoever connects to TCP port 4711; Lima forwards that port
// to this Mac's localhost. This program connects, plays the stream through AVAudioEngine
// (the Mac's current output device and volume), keeps the delay short by dropping audio
// that piles up, and reconnects whenever the VM restarts.
//
// Built and started by `bottle` (bottle start / bottle audio on); log: ~/.config/steamos-bottle/audio.log
//   bottle-audio [port]
import AVFoundation
import Darwin
import Foundation

let port = UInt16(CommandLine.arguments.dropFirst().first ?? "") ?? 4711
let sampleRate = 48000.0
let targetFrames = Int(sampleRate * 0.06)   // aim for ~60 ms of audio in hand
let maxFrames = Int(sampleRate * 0.15)      // more than 150 ms behind: catch up

setvbuf(stdout, nil, _IOLBF, 0)
signal(SIGPIPE, SIG_IGN)

func say(_ s: String) {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    print("\(f.string(from: Date())) \(s)")
}

/// Stereo float ring buffer shared by the network thread (writer) and the audio thread (reader).
final class Ring {
    private let cap: Int                       // in frames
    private let l: UnsafeMutablePointer<Float>
    private let r: UnsafeMutablePointer<Float>
    private var head = 0, count = 0            // read position, frames stored
    private let lock = NSLock()

    init(frames: Int) {
        cap = frames
        l = .allocate(capacity: frames); l.initialize(repeating: 0, count: frames)
        r = .allocate(capacity: frames); r.initialize(repeating: 0, count: frames)
    }

    /// Interleaved little-endian Int16 stereo frames.
    func write(_ p: UnsafePointer<Int16>, frames: Int) {
        lock.lock(); defer { lock.unlock() }
        for i in 0..<frames {
            if count == cap { head = (head + 1) % cap; count -= 1 }   // full: drop the oldest
            let w = (head + count) % cap
            l[w] = Float(Int16(littleEndian: p[2 * i])) / 32768
            r[w] = Float(Int16(littleEndian: p[2 * i + 1])) / 32768
            count += 1
        }
        if count > maxFrames {                  // fell behind: keep only the newest
            let drop = count - targetFrames
            head = (head + drop) % cap
            count -= drop
        }
    }

    func read(_ outL: UnsafeMutablePointer<Float>, _ outR: UnsafeMutablePointer<Float>, frames: Int) {
        lock.lock(); defer { lock.unlock() }
        for i in 0..<frames {
            if count > 0 {
                outL[i] = l[head]; outR[i] = r[head]
                head = (head + 1) % cap; count -= 1
            } else {
                outL[i] = 0; outR[i] = 0          // nothing yet: silence
            }
        }
    }

    func clear() { lock.lock(); head = 0; count = 0; lock.unlock() }
}

let ring = Ring(frames: Int(sampleRate))      // up to 1 s

// ---- playback ----
let engine = AVAudioEngine()
guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
    say("can't make the audio format"); exit(1)
}
let source = AVAudioSourceNode(format: format) { _, _, frameCount, bufferList -> OSStatus in
    let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
    guard buffers.count >= 2,
          let outL = buffers[0].mData?.assumingMemoryBound(to: Float.self),
          let outR = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
    ring.read(outL, outR, frames: Int(frameCount))
    return noErr
}
engine.attach(source)
engine.connect(source, to: engine.mainMixerNode, format: format)

func startEngine() {
    do { try engine.start() } catch { say("can't start audio output: \(error)") }
}
// Output device changed (headphones, AirPods, display speakers): start again on the new one.
NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { _ in
    say("audio output changed")
    engine.connect(source, to: engine.mainMixerNode, format: format)
    startEngine()
}
startEngine()

// ---- network ----
func connectOnce() -> Int32 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    if fd < 0 { return -1 }
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(port).bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    if rc != 0 { close(fd); return -1 }
    var one: Int32 = 1
    setsockopt(fd, Int32(IPPROTO_TCP), TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
    return fd
}

Thread.detachNewThread {
    let bufBytes = 16384
    let buf = UnsafeMutableRawPointer.allocate(byteCount: bufBytes, alignment: 4)
    var have = 0                                  // bytes in buf not yet consumed
    var playing = false
    while true {
        let fd = connectOnce()
        if fd < 0 { sleep(1); continue }
        have = 0
        while true {
            let n = recv(fd, buf + have, bufBytes - have, 0)
            if n <= 0 { break }
            if !playing { playing = true; say("connected: playing the bottle's sound (port \(port))") }
            have += n
            let frames = have / 4                 // 2 channels x 16 bit
            ring.write(buf.assumingMemoryBound(to: Int16.self), frames: frames)
            let rest = have - frames * 4
            if rest > 0 { memmove(buf, buf + frames * 4, rest) }
            have = rest
        }
        close(fd)
        if playing { say("disconnected (VM stopped?); waiting for it"); playing = false; ring.clear() }
        sleep(1)
    }
}

say("bottle-audio waiting for the VM's sound on port \(port)")
dispatchMain()
