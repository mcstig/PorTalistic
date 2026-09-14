//
//  WindowsExecutable.swift
//  Mythic
//
//  Created by Claude Opus 5 on 14/9/2026.
//

// Copyright © 2023-2025 vapidinfinity

import Foundation
import OSLog

/**
 What a Windows executable says about itself, read off disk without running it.

 Choosing a runtime for a game needs two facts above all others: whether it is 32-bit or
 64-bit, and which graphics API it renders with. Both are in the file. Nothing here launches
 anything, touches a container, or needs a runtime installed — which matters, because this
 has to answer *before* Mythic knows what to install.

 Two levels of evidence, kept apart because they aren't equally trustworthy:

 - **Imports.** Libraries named in the PE import tables. The loader resolves these before the
   program's first instruction, so an import is proof the binary needs that library.
 - **References.** Library names found as literals anywhere in the file. Weaker — a name can
   be left over from a dead code path — but it is usually the *only* evidence available,
   because modern engines reach Direct3D through `LoadLibrary` at runtime and import nothing.
   A game that picks its backend at startup shows up here and nowhere else.
 */
struct WindowsExecutable: Codable, Hashable {
    static let log: Logger = .custom(category: "WindowsExecutable")

    /// Path inspected, for logging and for the cache key.
    let url: URL

    let architecture: Architecture

    /// Libraries the loader must resolve before the program starts.
    let importedLibraries: Set<String>

    /// Libraries named anywhere in the file, including everything in ``importedLibraries``.
    let referencedLibraries: Set<String>

    /// True when the file was larger than ``scanByteLimit`` and only part of it was read for
    /// literals, so an absent reference is genuinely unknown rather than absent.
    let referenceScanWasTruncated: Bool

    enum Architecture: String, Codable, Hashable {
        /// 32-bit x86. Rules a great deal out: Apple's D3DMetal is 64-bit only, and so is
        /// DXMT, which leaves wined3d as the only way to render.
        case i386
        case x86_64
        /// A native ARM64 Windows binary. Vanishingly rare in games, and no runtime here
        /// runs one, but worth naming rather than guessing wrong about.
        case arm64
    }

    // MARK: - Graphics

    enum GraphicsAPI: String, Codable, Hashable, CaseIterable {
        case direct3D9, direct3D10, direct3D11, direct3D12, openGL, vulkan

        /// Which Direct3D this is, for "the highest one it asks for" comparisons.
        var direct3DVersion: Int? {
            switch self {
            case .direct3D9:    9
            case .direct3D10:   10
            case .direct3D11:   11
            case .direct3D12:   12
            case .openGL, .vulkan: nil
            }
        }

        var description: String {
            switch self {
            case .direct3D9:    "Direct3D 9"
            case .direct3D10:   "Direct3D 10"
            case .direct3D11:   "Direct3D 11"
            case .direct3D12:   "Direct3D 12"
            case .openGL:       "OpenGL"
            case .vulkan:       "Vulkan"
            }
        }
    }

    /// Library name to the API it implements.
    ///
    /// `dxgi.dll` is deliberately absent: it is the swap-chain layer shared by Direct3D 10
    /// onwards and says nothing about which of them a game uses. It's reported separately,
    /// by ``usesDXGI``, where it's useful as a floor — a binary that touches DXGI is not a
    /// Direct3D 9 game, whatever else it references.
    private static let graphicsLibraries: [String: GraphicsAPI] = [
        "d3d9.dll": .direct3D9,
        "d3d9on12.dll": .direct3D9,
        "d3d10.dll": .direct3D10,
        "d3d10_1.dll": .direct3D10,
        "d3d10core.dll": .direct3D10,
        "d3d11.dll": .direct3D11,
        "d3d11on12.dll": .direct3D11,
        "d3d12.dll": .direct3D12,
        "d3d12core.dll": .direct3D12,
        "opengl32.dll": .openGL,
        "vulkan-1.dll": .vulkan
    ]

    private static let dxgiLibrary = "dxgi.dll"

    /// Every graphics API the file mentions, on either level of evidence.
    var graphicsAPIs: Set<GraphicsAPI> {
        .init(referencedLibraries.compactMap { Self.graphicsLibraries[$0] })
    }

    /// The graphics APIs the loader will resolve — proof rather than inference.
    var importedGraphicsAPIs: Set<GraphicsAPI> {
        .init(importedLibraries.compactMap { Self.graphicsLibraries[$0] })
    }

    var usesDXGI: Bool {
        referencedLibraries.contains(Self.dxgiLibrary)
    }

    /// The newest Direct3D the file asks for, which is the one a runtime has to satisfy.
    ///
    /// A game that ships a Direct3D 9 fallback alongside its Direct3D 11 renderer mentions
    /// both; picking a runtime for the older one would work and look terrible.
    var highestDirect3DVersion: Int? {
        graphicsAPIs.compactMap(\.direct3DVersion).max()
    }

    /// Whether anything here suggests the binary renders at all.
    ///
    /// False for launchers, installers, crash handlers and redistributables — the things a
    /// game directory is full of, and the reason ``inspectGame(primaryExecutable:)`` keeps
    /// looking after the first file.
    var hasGraphicsEvidence: Bool {
        !graphicsAPIs.isEmpty || usesDXGI
    }

    // MARK: - Inspection

    enum ParseError: LocalizedError {
        case notAnExecutable
        case truncated
        case unsupportedMachine(UInt16)

        var errorDescription: String? {
            switch self {
            case .notAnExecutable:
                String(localized: "That file isn't a Windows executable.")
            case .truncated:
                String(localized: "That Windows executable is incomplete.")
            case .unsupportedMachine(let machine):
                String(localized: "Unrecognised executable architecture (0x\(String(machine, radix: 16))).")
            }
        }
    }

    /// Read one executable.
    ///
    /// Throws only when the file isn't a PE binary at all. Callers should treat a throw as
    /// "no evidence" and fall back to defaults: a game that can't be inspected still has to
    /// launch.
    static func inspect(_ url: URL) throws -> WindowsExecutable {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let file = FileWindow(handle: handle, size: (try? handle.seekToEnd()) ?? 0)

        let header = try PEHeader(reading: file)
        let imports = header.importedLibraries(from: file)
        let (references, truncated) = scanForLibraryNames(in: file)

        return .init(url: url,
                     architecture: header.architecture,
                     importedLibraries: imports,
                     referencedLibraries: imports.union(references),
                     referenceScanWasTruncated: truncated)
    }

    /// Inspect a game, starting from the executable Mythic would launch.
    ///
    /// The launch target is usually not the renderer, and on a modern game it usually isn't
    /// even the program. Measured on a real library:
    ///
    /// - **Prey**: the play task points at `Prey.exe`, which is under a megabyte. The game is
    ///   `PreyDll.dll`, 35MB, in the same directory.
    /// - **Horizon Chase Turbo**: `HorizonChase.exe`, under a megabyte, beside
    ///   `UnityPlayer.dll` at 22MB — every Unity game has this shape.
    ///
    /// Which is why DLLs are candidates and not just executables. Scanning only `.exe` files
    /// reported "nothing says how it renders" for both of those games and sent them to the
    /// fallback profile, while the answer was sitting next to the file being read. Largest
    /// first, because the renderer is the biggest binary in the folder and the noise —
    /// crash handlers, redistributables, GOG's and Epic's SDKs — is small.
    ///
    /// The primary's architecture is kept rather than the sibling's: the stub decides which
    /// process actually runs, and a 32-bit stub hands off to a 32-bit game.
    ///
    /// Bounded on purpose. A game directory can hold hundreds of binaries, and this runs
    /// before a launch.
    static func inspectGame(primaryExecutable: URL, searchLimit: Int = 12) -> WindowsExecutable? {
        // Reading a game can mean up to `scanByteLimit` bytes per executable across a dozen
        // of them, and provisioning walks the whole installed library on every pass. Keyed on
        // size and modification time as well as path, so a reinstall or a patch re-reads.
        let key = cacheKey(for: primaryExecutable)

        if let key, let cached = cached(for: key) { return cached }

        guard let primary = try? inspect(primaryExecutable) else { return nil }
        guard !primary.hasGraphicsEvidence else {
            if let key { store(primary, for: key) }
            return primary
        }

        let directory = primaryExecutable.deletingLastPathComponent()
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return primary }

        // Biggest first: the renderer is almost always the largest binary in the folder, and
        // the noise — crash handlers, installers, updaters — is small.
        let candidates = entries
            .filter { ["exe", "dll"].contains($0.pathExtension.lowercased()) }
            .filter { $0 != primaryExecutable }
            .filter { !isUninteresting($0) }
            .sorted { lhs, rhs in
                let left = (try? lhs.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let right = (try? rhs.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return left > right
            }
            .prefix(searchLimit)

        var imported = primary.importedLibraries
        var referenced = primary.referencedLibraries
        var truncated = primary.referenceScanWasTruncated

        for candidate in candidates {
            guard let inspected = try? inspect(candidate) else { continue }
            guard inspected.architecture == primary.architecture else { continue }

            imported.formUnion(inspected.importedLibraries)
            referenced.formUnion(inspected.referencedLibraries)
            truncated = truncated || inspected.referenceScanWasTruncated

            // One renderer is enough; keep walking only while nothing has been found.
            if !inspected.graphicsAPIs.isEmpty { break }
        }

        let merged: WindowsExecutable = .init(url: primary.url,
                                              architecture: primary.architecture,
                                              importedLibraries: imported,
                                              referencedLibraries: referenced,
                                              referenceScanWasTruncated: truncated)

        if let key { store(merged, for: key) }

        return merged
    }

    // MARK: - Cache

    private nonisolated(unsafe) static var inspections: [String: WindowsExecutable] = .init()
    private static let inspectionsLock: NSLock = .init()

    private static func cacheKey(for url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize,
              let modified = values.contentModificationDate else { return nil }

        return "\(url.path)|\(size)|\(modified.timeIntervalSince1970)"
    }

    private static func cached(for key: String) -> WindowsExecutable? {
        inspectionsLock.withLock { inspections[key] }
    }

    private static func store(_ executable: WindowsExecutable, for key: String) {
        inspectionsLock.withLock { inspections[key] = executable }
    }

    /// Names that are never the game.
    private static func isUninteresting(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()

        return ["unins", "vcredist", "vc_redist", "dxsetup", "dotnet", "directx",
                "crashhandler", "crashreport", "crashpad", "bsdiff", "7z", "setup",
                "installer", "redist", "oalinst", "dxwebsetup", "epicwebhelper",
                "eossdk", "steamerrorreporter", "touchupdater"]
            .contains { name.contains($0) }
    }

    // MARK: - Literal scan

    /// How much of a file is read looking for library names. Games ship 300MB executables
    /// with their assets packed in; the names are in the code, which is at the front.
    private static let scanByteLimit = 64 * 1024 * 1024
    private static let scanChunkSize = 4 * 1024 * 1024

    /// Every known library name appearing as a literal in the file.
    ///
    /// Both encodings are searched. `LoadLibraryW` takes a wide string, so an engine that
    /// calls it stores the name as UTF-16, and searching only for ASCII finds nothing in
    /// exactly the binaries this exists to catch.
    private static func scanForLibraryNames(in file: FileWindow) -> (names: Set<String>, truncated: Bool) {
        let needles: [(needle: Data, name: String)] = (Array(graphicsLibraries.keys) + [dxgiLibrary])
            .flatMap { name -> [(Data, String)] in
                let ascii = Data(name.utf8)
                let wide = Data(name.utf8.flatMap { [$0, 0] })
                return [(ascii, name), (wide, name)]
            }

        let overlap = needles.map(\.needle.count).max().map { $0 - 1 } ?? 0

        var found: Set<String> = .init()
        var offset: UInt64 = 0
        var carry: Data = .init()
        var scanned = 0

        while offset < file.size, scanned < scanByteLimit {
            let budget = min(scanChunkSize, scanByteLimit - scanned)
            guard let chunk = try? file.bytes(at: offset, count: budget), !chunk.isEmpty else { break }

            offset += UInt64(chunk.count)
            scanned += chunk.count

            // Case-folded once per chunk rather than once per needle. Windows library names
            // appear in every casing imaginable — `D3D11.DLL`, `d3d11.dll`, `D3d11.Dll`.
            let window = lowercasedASCII(carry + chunk)

            for (needle, name) in needles where !found.contains(name) {
                if window.range(of: needle) != nil { found.insert(name) }
            }

            carry = overlap > 0 ? Data(window.suffix(overlap)) : .init()
        }

        return (found, scanned >= scanByteLimit && offset < file.size)
    }

    private static func lowercasedASCII(_ data: Data) -> Data {
        Data(data.map { byte in (byte >= 0x41 && byte <= 0x5A) ? byte + 0x20 : byte })
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case url, architecture, importedLibraries, referencedLibraries, referenceScanWasTruncated
    }
}

// MARK: - File access

/// Random access over a file without reading it into memory.
private struct FileWindow {
    let handle: FileHandle
    let size: UInt64

    func bytes(at offset: UInt64, count: Int) throws -> Data {
        guard count > 0, offset < size else { return .init() }
        try handle.seek(toOffset: offset)
        return try handle.read(upToCount: count) ?? .init()
    }

    /// A NUL-terminated ASCII string at a file offset, as library names are stored.
    func cString(at offset: UInt64, limit: Int = 256) -> String? {
        guard let data = try? bytes(at: offset, count: limit), !data.isEmpty else { return nil }
        guard let terminator = data.firstIndex(of: 0) else { return nil }

        let bytes = data[data.startIndex..<terminator]
        guard !bytes.isEmpty, bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return nil }

        return String(decoding: bytes, as: UTF8.self)
    }
}

// MARK: - PE

/// Just enough of the PE format to answer "how wide is it" and "what does it link against".
private struct PEHeader {
    let architecture: WindowsExecutable.Architecture
    let sections: [Section]
    /// Data directory entries, by their fixed index. 1 is imports, 13 is delay-load imports.
    let dataDirectories: [(rva: UInt32, size: UInt32)]

    struct Section {
        let virtualAddress: UInt32
        let virtualSize: UInt32
        let rawDataOffset: UInt32
        let rawDataSize: UInt32
    }

    init(reading file: FileWindow) throws {
        // DOS header: "MZ", then the offset of the real header at 0x3C. Every PE binary
        // still carries this, forty years on.
        let dos = try file.bytes(at: 0, count: 64)
        guard dos.count == 64 else { throw WindowsExecutable.ParseError.truncated }
        guard dos.uint16(at: 0) == 0x5A4D else { throw WindowsExecutable.ParseError.notAnExecutable }
        guard let peOffset = dos.uint32(at: 0x3C) else { throw WindowsExecutable.ParseError.truncated }

        // Signature, then the 20-byte COFF header.
        let coff = try file.bytes(at: UInt64(peOffset), count: 24)
        guard coff.count == 24 else { throw WindowsExecutable.ParseError.truncated }
        guard coff.uint32(at: 0) == 0x0000_4550 else { throw WindowsExecutable.ParseError.notAnExecutable }

        guard let machine = coff.uint16(at: 4),
              let sectionCount = coff.uint16(at: 6),
              let optionalHeaderSize = coff.uint16(at: 20) else {
            throw WindowsExecutable.ParseError.truncated
        }

        switch machine {
        case 0x014C: architecture = .i386
        case 0x8664: architecture = .x86_64
        case 0xAA64: architecture = .arm64
        default: throw WindowsExecutable.ParseError.unsupportedMachine(machine)
        }

        // The optional header (never optional in practice) differs between PE32 and PE32+ by
        // the width of a handful of address fields, which moves the data directory.
        let optionalHeaderOffset = UInt64(peOffset) + 24
        let optionalHeader = try file.bytes(at: optionalHeaderOffset, count: Int(optionalHeaderSize))
        guard let magic = optionalHeader.uint16(at: 0) else { throw WindowsExecutable.ParseError.truncated }

        let directoryOffset: Int
        switch magic {
        case 0x010B: directoryOffset = 96   // PE32
        case 0x020B: directoryOffset = 112  // PE32+
        default: throw WindowsExecutable.ParseError.notAnExecutable
        }

        let declaredCount = Int(optionalHeader.uint32(at: directoryOffset - 4) ?? 0)
        var directories: [(rva: UInt32, size: UInt32)] = []

        for index in 0..<min(declaredCount, 16) {
            let entry = directoryOffset + index * 8
            guard let rva = optionalHeader.uint32(at: entry),
                  let size = optionalHeader.uint32(at: entry + 4) else { break }
            directories.append((rva, size))
        }

        dataDirectories = directories

        // Section headers follow the optional header, and are what turn a virtual address
        // into a file offset.
        let sectionTableOffset = optionalHeaderOffset + UInt64(optionalHeaderSize)
        let sectionTable = try file.bytes(at: sectionTableOffset, count: Int(sectionCount) * 40)

        sections = (0..<Int(sectionCount)).compactMap { index in
            let base = index * 40
            guard let virtualSize = sectionTable.uint32(at: base + 8),
                  let virtualAddress = sectionTable.uint32(at: base + 12),
                  let rawDataSize = sectionTable.uint32(at: base + 16),
                  let rawDataOffset = sectionTable.uint32(at: base + 20) else { return nil }

            return .init(virtualAddress: virtualAddress,
                         virtualSize: virtualSize,
                         rawDataOffset: rawDataOffset,
                         rawDataSize: rawDataSize)
        }
    }

    /// Where a virtual address lives in the file, if anywhere.
    func fileOffset(forRVA rva: UInt32) -> UInt64? {
        for section in sections {
            let span = max(section.virtualSize, section.rawDataSize)
            guard rva >= section.virtualAddress, rva < section.virtualAddress &+ span else { continue }
            return UInt64(section.rawDataOffset &+ (rva &- section.virtualAddress))
        }
        return nil
    }

    /// Library names from both import tables, lowercased.
    ///
    /// Delay-load imports are included because they are imports as far as this is concerned:
    /// a game that delay-loads `d3d11.dll` still cannot render without it, and several do.
    func importedLibraries(from file: FileWindow) -> Set<String> {
        var names: Set<String> = .init()

        // Standard imports: 20-byte descriptors, name RVA at +12, terminated by a zeroed one.
        if dataDirectories.count > 1, dataDirectories[1].rva != 0 {
            names.formUnion(walkDescriptors(at: dataDirectories[1].rva,
                                            stride: 20,
                                            nameFieldOffset: 12,
                                            in: file))
        }

        // Delay-load imports: 32-byte descriptors, name RVA at +4.
        if dataDirectories.count > 13, dataDirectories[13].rva != 0 {
            names.formUnion(walkDescriptors(at: dataDirectories[13].rva,
                                            stride: 32,
                                            nameFieldOffset: 4,
                                            in: file))
        }

        return names
    }

    private func walkDescriptors(at rva: UInt32,
                                 stride: Int,
                                 nameFieldOffset: Int,
                                 in file: FileWindow,
                                 limit: Int = 4096) -> Set<String> {
        guard let base = fileOffset(forRVA: rva) else { return .init() }

        var names: Set<String> = .init()

        for index in 0..<limit {
            let offset = base + UInt64(index * stride)
            guard let descriptor = try? file.bytes(at: offset, count: stride),
                  descriptor.count == stride else { break }

            // A descriptor of all zeroes ends the table.
            guard descriptor.contains(where: { $0 != 0 }) else { break }

            guard let nameRVA = descriptor.uint32(at: nameFieldOffset), nameRVA != 0,
                  let nameOffset = fileOffset(forRVA: nameRVA),
                  let name = file.cString(at: nameOffset) else { continue }

            // Delay-load tables in older binaries hold absolute addresses rather than RVAs,
            // which resolve to nonsense. Requiring a library name is the cheap way to tell.
            guard name.lowercased().hasSuffix(".dll") else { continue }

            names.insert(name.lowercased())
        }

        return names
    }
}

// MARK: - Little-endian reads

private extension Data {
    /// Slices keep their parent's indices, so every read is relative to `startIndex`.
    func uint16(at index: Int) -> UInt16? {
        guard index >= 0, index + 2 <= count else { return nil }
        let base = startIndex + index
        return UInt16(self[base]) | (UInt16(self[base + 1]) << 8)
    }

    func uint32(at index: Int) -> UInt32? {
        guard index >= 0, index + 4 <= count else { return nil }
        let base = startIndex + index
        return UInt32(self[base])
            | (UInt32(self[base + 1]) << 8)
            | (UInt32(self[base + 2]) << 16)
            | (UInt32(self[base + 3]) << 24)
    }
}
