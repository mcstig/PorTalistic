// Portalistic — a game's rumble, played on a Mac controller with Core Haptics.

import Foundation
import CoreHaptics
import GameController

/// The game's rumble on a Mac controller: the strong (low) motor in the left handle and the
/// weak (high) one in the right, as on an Xbox pad; one engine for pads that can't split them.
final class Rumbler {
    private var left: CHHapticEngine?, right: CHHapticEngine?, whole: CHHapticEngine?
    private var players: [CHHapticPatternPlayer] = []

    init(_ c: GCController) {
        guard let h = c.haptics else { return }
        let places = h.supportedLocalities
        if places.contains(.leftHandle) && places.contains(.rightHandle) {
            left = h.createEngine(withLocality: .leftHandle)
            right = h.createEngine(withLocality: .rightHandle)
        } else {
            whole = h.createEngine(withLocality: .default)
        }
        for e in [left, right, whole].compactMap({ $0 }) {
            e.playsHapticsOnly = true
            e.resetHandler = { [weak e] in try? e?.start() }
        }
    }

    func play(strong: Float, weak: Float, seconds: Double) {
        stop()
        guard seconds > 0 else { return }
        if let l = left, let r = right {
            start(l, strong, seconds)
            start(r, weak, seconds)
        } else if let w = whole {
            start(w, max(strong, weak), seconds)
        }
    }

    private func start(_ e: CHHapticEngine, _ intensity: Float, _ seconds: Double) {
        guard intensity > 0.01 else { return }
        do {
            try e.start()
            let event = CHHapticEvent(eventType: .hapticContinuous,
                                      parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity)],
                                      relativeTime: 0, duration: seconds)
            let player = try e.makePlayer(with: CHHapticPattern(events: [event], parameters: []))
            try player.start(atTime: CHHapticTimeImmediate)
            players.append(player)
        } catch {
            // no rumble on this controller; the game plays on
        }
    }

    func stop() {
        for p in players { try? p.stop(atTime: CHHapticTimeImmediate) }
        players.removeAll()
    }
}
