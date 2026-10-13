// Portalistic — the Library's colours, from the app icon.

import Foundation
import SwiftUI

/// The colours of the app's icon: deep navy glass, and the bottle's teal-to-violet liquid
/// (used for Play only).
enum Palette {
    static let ink = Color(red: 0x10 / 255, green: 0x16 / 255, blue: 0x2B / 255)
    static let deep = Color(red: 0x0B / 255, green: 0x10 / 255, blue: 0x20 / 255)
    static let panel = Color(red: 0x19 / 255, green: 0x21 / 255, blue: 0x3D / 255)
    static let text = Color(red: 0xEE / 255, green: 0xF2 / 255, blue: 1)
    static let muted = Color(red: 0x9A / 255, green: 0xA6 / 255, blue: 0xC8 / 255)
    static let teal = Color(red: 0x46 / 255, green: 0xD6 / 255, blue: 0xE6 / 255)
    static let violet = Color(red: 0x7C / 255, green: 0x5C / 255, blue: 0xF6 / 255)
    static var liquid: LinearGradient { LinearGradient(colors: [teal, violet], startPoint: .topLeading, endPoint: .bottomTrailing) }
    static var backdrop: LinearGradient { LinearGradient(colors: [ink, deep], startPoint: .top, endPoint: .bottom) }
}
