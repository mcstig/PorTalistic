// Portalistic — runs the kit's `bottle` command (host/bottle) for the app.

import AppKit

/// Runs the kit's `bottle` command for the app. Its output goes to a log file in the kit's logs
/// folder rather than a pipe, so a command carries on when the app quits (starting the VM,
/// shutting it down, the app's own rebuild); while the app is open it follows the file.
final class BottleCommand {
    /// The kit inside a packaged app (host/package-app.sh): Contents/Resources/kit. Lima, krunkit
    /// and KosmicKrisp come with the app then too, logs go to ~/Library/Logs/Portalistic, and the
    /// app updates as a whole. A development build points at the kit folder it was built from.
    static let bundledKit: String? = Bundle.main.resourcePath.map { $0 + "/kit" }
        .flatMap { FileManager.default.fileExists(atPath: $0 + "/host/bottle") ? $0 : nil }
    static var isPackaged: Bool { bundledKit != nil }
    static let kitDir = bundledKit ?? (Bundle.main.object(forInfoDictionaryKey: "BottleKitDir") as? String)
        .flatMap { $0.isEmpty ? nil : ($0 as NSString).standardizingPath }
    static var script: String? { kitDir.map { $0 + "/host/bottle" } }
    static var available: Bool { script.map { FileManager.default.fileExists(atPath: $0) } ?? false }
    static var logDir: String {
        isPackaged ? NSHomeDirectory() + "/Library/Logs/Portalistic" : (kitDir ?? NSTemporaryDirectory()) + "/logs"
    }

    /// The PATH the kit was built with (Homebrew's limactl...), then the usual folders.
    static var path: String {
        let saved = Bundle.main.object(forInfoDictionaryKey: "BottlePath") as? String ?? ""
        let usual = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        let helpers = isPackaged ? Bundle.main.bundlePath + "/Contents/Helpers/bin:" : ""
        return helpers + (saved.isEmpty ? usual : saved + ":" + usual)
    }

    let args: [String]
    let logPath: String
    var onLine: ((String) -> Void)?             // main thread, each line without colours
    var onExit: ((Int32) -> Void)?              // main thread
    private(set) var lines: [String] = []
    private(set) var running = false
    private let process = Process()
    private var reader: FileHandle?
    private var timer: Timer?
    private var pending = Data()

    init(_ args: [String], log name: String) {
        self.args = args
        logPath = BottleCommand.logDir + "/app-\(name).log"
    }

    /// The last line saying what went wrong ("error: ..."), else the last line.
    var problem: String {
        if let e = lines.last(where: { $0.hasPrefix("error: ") }) { return String(e.dropFirst(7)) }
        return readableLine(lines.last(where: { !$0.isEmpty }) ?? "")
    }

    func start() -> Bool {
        guard let script = BottleCommand.script else { return false }
        let fm = FileManager.default
        try? fm.createDirectory(atPath: BottleCommand.logDir, withIntermediateDirectories: true)
        guard fm.createFile(atPath: logPath, contents: nil),
              let out = FileHandle(forWritingAtPath: logPath),
              let inp = FileHandle(forReadingAtPath: logPath) else { return false }
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script] + args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = BottleCommand.path
        env["BOTTLE_FROM_APP"] = "1"
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = out
        process.terminationHandler = { p in
            let status = p.terminationStatus
            DispatchQueue.main.async { self.finish(status) }
        }
        do { try process.run() } catch { try? out.close(); try? inp.close(); return false }
        try? out.close()                         // the command has its own copy
        reader = inp
        running = true
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        return true
    }

    /// Ends the command (its output stops being followed when it exits).
    func stop() { if running { process.terminate() } }

    private func poll() {
        guard let r = reader else { return }
        guard let data = try? r.readToEnd(), !data.isEmpty else { return }
        pending.append(data)
        while let nl = pending.firstIndex(of: 0x0a) {
            let raw = pending.subdata(in: pending.startIndex..<nl)
            pending.removeSubrange(pending.startIndex...nl)
            emit(String(decoding: raw, as: UTF8.self))
        }
    }

    private func emit(_ raw: String) {
        var line = raw.replacingOccurrences(of: "\u{1b}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        while line.hasSuffix("\r") { line.removeLast() }
        if let cr = line.lastIndex(of: "\r") { line = String(line[line.index(after: cr)...]) }   // progress bars
        lines.append(line)
        if lines.count > 4000 { lines.removeFirst(lines.count - 4000) }
        onLine?(line)
    }

    private func finish(_ status: Int32) {
        poll()
        if !pending.isEmpty { emit(String(decoding: pending, as: UTF8.self)); pending.removeAll() }
        timer?.invalidate(); timer = nil
        try? reader?.close(); reader = nil
        running = false
        process.terminationHandler = nil
        onExit?(status)
    }
}

/// A friendlier line for the starting screen: Lima's `time=... level=info msg="..."` lines
/// become just the message.
func readableLine(_ line: String) -> String {
    var s = line
    if let r = s.range(of: "msg=\"") {
        s = String(s[r.upperBound...])
        if s.hasSuffix("\"") { s.removeLast() }
        s = s.replacingOccurrences(of: "\\\"", with: "\"")
    }
    for prefix in ["[hostagent] ", "==> "] where s.hasPrefix(prefix) { s.removeFirst(prefix.count) }
    return s
}
