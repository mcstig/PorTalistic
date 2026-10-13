// Portalistic — the screen protocol (see guest/screen/bottle-screen.c).
//
// Messages are an 8-byte header (type, 3 zero bytes, little-endian u32 length) and a body.
// The VM sends the screen and the cursor; the app sends input, controllers and settings.

import Foundation

enum ServerMsg {
    static let hello: UInt8 = 1, frame: UInt8 = 2, cursor: UInt8 = 3, rumble: UInt8 = 4, padStatus: UInt8 = 5
    static let stats: UInt8 = 6
    static let notice: UInt8 = 7          // version 2: something for the player to read (a game that closed, say)
}

enum ClientMsg {
    static let key: UInt8 = 1, moveRel: UInt8 = 2, moveAbs: UInt8 = 3, button: UInt8 = 4
    static let wheel: UInt8 = 5, settings: UInt8 = 6, release: UInt8 = 7, pad: UInt8 = 8
    static let resize: UInt8 = 9          // version 2: the screen size the window wants, and for games
    static let hostStats: UInt8 = 10      // version 2: the Mac's GPU numbers, for Steam's performance monitor
}

func le16(_ v: Int) -> [UInt8] { let u = UInt16(truncatingIfNeeded: v); return [UInt8(u & 0xff), UInt8(u >> 8)] }

func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8(v >> 24)] }

func rd16(_ p: UnsafeRawPointer, _ o: Int) -> Int { Int(p.load(fromByteOffset: o, as: UInt8.self)) | Int(p.load(fromByteOffset: o + 1, as: UInt8.self)) << 8 }

func rd32(_ p: UnsafeRawPointer, _ o: Int) -> Int { rd16(p, o) | rd16(p, o + 2) << 16 }

let screenPort = UInt16(ProcessInfo.processInfo.environment["BOTTLE_SCREEN_PORT"] ?? "") ?? 4720

let jpegQuality = UInt8(ProcessInfo.processInfo.environment["BOTTLE_SCREEN_QUALITY"] ?? "") ?? 85

let fixedFPS = UInt8(ProcessInfo.processInfo.environment["BOTTLE_SCREEN_FPS"] ?? "")   // overrides the menu

/// SETTINGS feature bits (bottle-screen.c): 1 = partial frames, sharp stills and STATS.
let screenFeatures: UInt8 = 1
