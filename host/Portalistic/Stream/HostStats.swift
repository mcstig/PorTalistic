// Portalistic — the Mac's GPU numbers for Steam's performance monitor in the VM.
//
// Once a second, while the VM's screen server is connected (version 2), this sends HOST_STATS:
// the GPU's load and the memory it uses (the GPU driver's own statistics in the I/O Registry,
// the numbers Activity Monitor's GPU History shows), its name, and the chip's temperature (the
// hottest die sensor, read the way Mac monitoring tools do, through the HID event system; when
// that isn't available the temperature is just left out). In the VM, bottle-screen writes them
// to /dev/shm and the bottle's NVML stand-in (guest/nvml) hands them to Steam's overlay.

import Foundation
import IOKit
import Metal

final class HostStats {
    private let conn: Connection
    private let queue = DispatchQueue(label: "bottle.hoststats", qos: .utility)
    private var timer: DispatchSourceTimer?
    private let gpuName: String
    private let gpuMemoryMB: UInt32
    private let thermal = Thermal()

    init(conn: Connection) {
        self.conn = conn
        let dev = MTLCreateSystemDefaultDevice()
        gpuName = dev?.name ?? "Mac GPU"
        // what Metal lets one app use of the shared memory: the closest thing to "VRAM" here
        gpuMemoryMB = UInt32(min(UInt64(UInt32.max), (dev?.recommendedMaxWorkingSetSize ?? 0) / 1_048_576))
    }

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
        t.setEventHandler { [weak self] in self?.sample() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func sample() {
        let (load, used) = HostStats.acceleratorStats()
        let temp = thermal.hottestDie()
        var body: [UInt8] = []
        body.append(load.map { UInt8(clamping: $0) } ?? 255)
        body.append(0)
        body += le16(temp.map { Int(($0 * 10).rounded()) } ?? 0)
        body += le32(used.map { UInt32(min(UInt64(UInt32.max), $0 / 1_048_576)) } ?? 0)
        body += le32(gpuMemoryMB)
        body += Array(gpuName.utf8.prefix(100))
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.conn.serverVersion >= 2 else { return }
            self.conn.send(ClientMsg.hostStats, body)
        }
    }

    /// The GPU's load (%) and the memory it has in use (bytes), from its driver's statistics.
    static func acceleratorStats() -> (Int?, UInt64?) {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iter) == KERN_SUCCESS else {
            return (nil, nil)
        }
        defer { IOObjectRelease(iter) }
        var load: Int?, used: UInt64?
        var entry = IOIteratorNext(iter)
        while entry != 0 {
            if let ref = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0),
               let stats = ref.takeRetainedValue() as? [String: Any] {
                if let u = (stats["Device Utilization %"] as? NSNumber)?.intValue { load = max(load ?? 0, u) }
                if let m = (stats["In use system memory"] as? NSNumber)?.uint64Value { used = max(used ?? 0, m) }
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iter)
        }
        return (load, used)
    }
}

/// The chip's temperatures through the HID event system (IOHIDEventSystemClient, the part of
/// IOKit macOS's own thermal tools use; not public API, so every function is looked up and
/// anything missing just means no temperature).
private final class Thermal {
    private typealias CreateFn = @convention(c) (CFAllocator?) -> UnsafeMutableRawPointer?
    private typealias SetMatchingFn = @convention(c) (UnsafeMutableRawPointer, CFDictionary) -> Int32
    private typealias CopyServicesFn = @convention(c) (UnsafeMutableRawPointer) -> Unmanaged<CFArray>?
    private typealias CopyPropertyFn = @convention(c) (UnsafeRawPointer, CFString) -> Unmanaged<CFTypeRef>?
    private typealias CopyEventFn = @convention(c) (UnsafeRawPointer, Int64, Int32, Int64) -> UnsafeMutableRawPointer?
    private typealias GetFloatFn = @convention(c) (UnsafeRawPointer, Int32) -> Double

    private var client: UnsafeMutableRawPointer?
    private var copyServices: CopyServicesFn?
    private var copyProperty: CopyPropertyFn?
    private var copyEvent: CopyEventFn?
    private var getFloat: GetFloatFn?
    private var failed = false

    private static let temperatureEvent: Int64 = 15               // kIOHIDEventTypeTemperature
    private static let temperatureField: Int32 = 15 << 16         // its level field

    private func setUp() -> Bool {
        if client != nil { return true }
        if failed { return false }
        failed = true
        guard let h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
              let pCreate = dlsym(h, "IOHIDEventSystemClientCreate"),
              let pMatch = dlsym(h, "IOHIDEventSystemClientSetMatching"),
              let pServices = dlsym(h, "IOHIDEventSystemClientCopyServices"),
              let pProperty = dlsym(h, "IOHIDServiceClientCopyProperty"),
              let pEvent = dlsym(h, "IOHIDServiceClientCopyEvent"),
              let pFloat = dlsym(h, "IOHIDEventGetFloatValue") else { return false }
        let create = unsafeBitCast(pCreate, to: CreateFn.self)
        let setMatching = unsafeBitCast(pMatch, to: SetMatchingFn.self)
        guard let c = create(kCFAllocatorDefault) else { return false }
        // the temperature sensors: vendor page 0xff00, usage 5
        let match = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary
        _ = setMatching(c, match)
        client = c
        copyServices = unsafeBitCast(pServices, to: CopyServicesFn.self)
        copyProperty = unsafeBitCast(pProperty, to: CopyPropertyFn.self)
        copyEvent = unsafeBitCast(pEvent, to: CopyEventFn.self)
        getFloat = unsafeBitCast(pFloat, to: GetFloatFn.self)
        failed = false
        return true
    }

    /// The hottest die sensor in °C ("PMU tdie…" on Apple silicon), or nil.
    func hottestDie() -> Double? {
        guard setUp(), let c = client, let services = copyServices?(c)?.takeRetainedValue(),
              let copyProperty = copyProperty, let copyEvent = copyEvent, let getFloat = getFloat else { return nil }
        var hottest: Double?
        for i in 0..<CFArrayGetCount(services) {
            guard let service = CFArrayGetValueAtIndex(services, i) else { continue }
            let name = (copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String) ?? ""
            guard name.contains("tdie") else { continue }
            guard let event = copyEvent(service, Thermal.temperatureEvent, 0, 0) else { continue }
            let t = getFloat(UnsafeRawPointer(event), Thermal.temperatureField)
            Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(event)).release()
            if t > 5 && t < 150 { hottest = max(hottest ?? t, t) }
        }
        return hottest
    }
}
