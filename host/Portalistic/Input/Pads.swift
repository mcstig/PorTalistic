// Portalistic — the Mac's game controllers as virtual Xbox 360 pads in the VM.

import Foundation
import GameController
import IOKit.pwr_mgt

/// The Mac's game controllers as virtual Xbox 360 pads in the VM (up to four). Xbox, DualSense,
/// DualShock and other pads all show up in GameController as an "extended gamepad" with the
/// same layout (A/Cross at the bottom), so they map the same way. PlayStation's Create button
/// and touchpad click act as Back (View); the PS / Xbox button as Guide.
///
/// Slot i drives the VM's pad i, and most games only listen to player 1 (pad 0). So the
/// controller in use is player 1: slots stay packed when one disconnects, and a controller in a
/// later slot that's used while player 1's has been idle for `idleSwap` seconds swaps places
/// with it (say, the DualSense picked up while the Xbox pad is still on). Two players playing
/// at once keep their slots.
final class Pads {
    private let conn: Connection
    private var slots: [GCController?] = Array(repeating: nil, count: 4)
    private var last: [[UInt8]] = Array(repeating: [], count: 4)
    private var rumblers: [Rumbler?] = Array(repeating: nil, count: 4)
    private var lastUsed: [TimeInterval] = Array(repeating: 0, count: 4)   // 0 = not yet
    private let idleSwap: TimeInterval = 30
    private var activityID: IOPMAssertionID = 0
    private var lastActivity: TimeInterval = 0
    var onChange: (() -> Void)?

    init(conn: Connection) {
        self.conn = conn
        let nc = NotificationCenter.default
        nc.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] n in
            if let c = n.object as? GCController { self?.add(c) }
        }
        nc.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] n in
            if let c = n.object as? GCController { self?.remove(c) }
        }
        for c in GCController.controllers() { add(c) }
    }

    /// The controllers in player order (player 1 first).
    var names: [String] { slots.compactMap { $0 }.map { $0.vendorName ?? "Controller" } }

    private func add(_ c: GCController) {
        guard let g = c.extendedGamepad, !slots.contains(where: { $0 === c }),
              let i = slots.firstIndex(where: { $0 == nil }) else { return }
        slots[i] = c
        // Every button goes to the game: no Game Overlay on the Home button, no screenshot on Share.
        for b in g.allButtons { b.preferredSystemGestureState = .disabled }
        // The handler finds the controller's slot each time: slots change when players swap.
        g.valueChangedHandler = { [weak self, weak c] _, _ in
            guard let self = self, let c = c, let k = self.slots.firstIndex(where: { $0 === c }) else { return }
            self.changed(k)
        }
        rumblers[i] = Rumbler(c)
        lastUsed[i] = 0
        placed(i)
        onChange?()
    }

    private func remove(_ c: GCController) {
        guard let i = slots.firstIndex(where: { $0 === c }) else { return }
        slots[i] = nil
        rumblers[i]?.stop()
        rumblers[i] = nil
        // Close the gap: the players after it move up one (player 2 becomes player 1...).
        var gap = i
        while gap + 1 < slots.count, slots[gap + 1] != nil {
            move(gap + 1, to: gap)
            gap += 1
        }
        last[gap] = []
        conn.send(ClientMsg.pad, [UInt8(gap), 0] + [UInt8](repeating: 0, count: 14))   // centered
        onChange?()
    }

    /// Slot i has a (new) controller: its player light, and the VM's pad i gets its state.
    private func placed(_ i: Int) {
        slots[i]?.playerIndex = GCControllerPlayerIndex(rawValue: i) ?? .indexUnset
        last[i] = []
        send(i)
    }

    private func move(_ from: Int, to: Int) {
        slots[to] = slots[from]; slots[from] = nil
        rumblers[from]?.stop()
        rumblers[to] = rumblers[from]; rumblers[from] = nil
        lastUsed[to] = lastUsed[from]; lastUsed[from] = 0
        placed(to)
    }

    private func swapPlayers(_ a: Int, _ b: Int) {
        slots.swapAt(a, b)
        rumblers[a]?.stop(); rumblers[b]?.stop()
        rumblers.swapAt(a, b)
        lastUsed.swapAt(a, b)
        placed(a); placed(b)
        onChange?()
    }

    /// Input from slot k's controller.
    private func changed(_ k: Int) {
        guard let g = slots[k]?.extendedGamepad else { return }
        if inUse(g) {
            let now = ProcessInfo.processInfo.systemUptime
            let p1Busy = slots[0]?.extendedGamepad.map { inUse($0) } ?? false   // e.g. a button held down
            if k > 0 && now - lastUsed[0] > idleSwap && !p1Busy {   // player 1's controller sits idle: take over
                swapPlayers(0, k)
                lastUsed[0] = now
                return
            }
            lastUsed[k] = now
        }
        send(k)
    }

    /// Really being used: a button, a trigger, the d-pad or a stick pushed well past drift.
    private func inUse(_ g: GCExtendedGamepad) -> Bool {
        if g.allButtons.contains(where: { $0.isPressed }) { return true }
        return [g.leftThumbstick, g.rightThumbstick, g.dpad].contains {
            abs($0.xAxis.value) > 0.5 || abs($0.yAxis.value) > 0.5
        }
    }

    /// buttons u16, sticks 4 x i16 (y > 0 = down), triggers 2 x u8, d-pad x/y as i8
    private func state(_ g: GCExtendedGamepad) -> [UInt8] {
        var b = 0
        func bit(_ on: Bool, _ n: Int) { if on { b |= 1 << n } }
        bit(g.buttonA.isPressed, 0); bit(g.buttonB.isPressed, 1)
        bit(g.buttonX.isPressed, 2); bit(g.buttonY.isPressed, 3)
        bit(g.leftShoulder.isPressed, 4); bit(g.rightShoulder.isPressed, 5)
        var back = g.buttonOptions?.isPressed ?? false
        if let ds = g as? GCDualSenseGamepad, ds.touchpadButton.isPressed { back = true }
        if let ds = g as? GCDualShockGamepad, ds.touchpadButton.isPressed { back = true }
        bit(back, 6)
        bit(g.buttonMenu.isPressed, 7)
        bit(g.buttonHome?.isPressed ?? false, 8)
        bit(g.leftThumbstickButton?.isPressed ?? false, 9)
        bit(g.rightThumbstickButton?.isPressed ?? false, 10)
        func axis(_ v: Float) -> Int { Int((max(-1, min(1, v)) * 32767).rounded()) }
        func trigger(_ v: Float) -> UInt8 { UInt8((max(0, min(1, v)) * 255).rounded()) }
        let dx = (g.dpad.right.isPressed ? 1 : 0) - (g.dpad.left.isPressed ? 1 : 0)
        let dy = (g.dpad.down.isPressed ? 1 : 0) - (g.dpad.up.isPressed ? 1 : 0)
        var m = le16(b)
        m += le16(axis(g.leftThumbstick.xAxis.value)) + le16(axis(-g.leftThumbstick.yAxis.value))
        m += le16(axis(g.rightThumbstick.xAxis.value)) + le16(axis(-g.rightThumbstick.yAxis.value))
        m += [trigger(g.leftTrigger.value), trigger(g.rightTrigger.value),
              UInt8(bitPattern: Int8(dx)), UInt8(bitPattern: Int8(dy))]
        return m
    }

    private func send(_ i: Int) {
        guard let g = slots[i]?.extendedGamepad else { return }
        let s = state(g)
        guard s != last[i] else { return }
        last[i] = s
        conn.send(ClientMsg.pad, [UInt8(i), 1] + s)
        declareActivity()
    }

    /// Controller input counts as using the Mac (macOS doesn't count it by itself): otherwise a
    /// game played with only a controller lets the display dim and sleep.
    private func declareActivity() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastActivity > 5 else { return }
        lastActivity = now
        IOPMAssertionDeclareUserActivity("Portalistic: game controller" as CFString, kIOPMUserActiveLocal, &activityID)
    }

    /// After a reconnect or coming back to the app: the VM gets every pad's current state.
    func resendAll() { for i in 0..<slots.count { last[i] = []; send(i) } }

    /// The app lost focus: the VM centers the pads (RELEASE), so forget what it was sent.
    func forget() {
        for i in 0..<slots.count { last[i] = []; rumblers[i]?.stop() }
    }

    func rumble(_ i: Int, strong: Float, weak: Float, seconds: Double) {
        guard i >= 0, i < rumblers.count else { return }
        rumblers[i]?.play(strong: strong, weak: weak, seconds: seconds)
    }
}
