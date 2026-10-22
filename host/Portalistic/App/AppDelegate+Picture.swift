// Portalistic — picture settings (View menu): frame rate, sharp scaling, Stream Info.

import AppKit
import QuartzCore

extension AppDelegate {
    /// Smooth Motion: as many frames as the display shows (up to 120 on ProMotion), else 60.
    func frameRate() -> UInt8 {
        let smooth = UserDefaults.standard.object(forKey: smoothKey) as? Bool ?? true
        let screenMax = (window?.screen ?? NSScreen.main)?.maximumFramesPerSecond ?? 60
        return UInt8(smooth ? max(30, min(120, screenMax)) : 60)
    }

    @objc func toggleSharp(_ sender: Any?) {
        let on = !(UserDefaults.standard.object(forKey: sharpKey) as? Bool ?? true)
        UserDefaults.standard.set(on, forKey: sharpKey)
        view.renderer?.sharpScaling = on
        view.redraw()
    }

    @objc func toggleSmooth(_ sender: Any?) {
        let on = !(UserDefaults.standard.object(forKey: smoothKey) as? Bool ?? true)
        UserDefaults.standard.set(on, forKey: smoothKey)
        conn.setFrameRate(frameRate())
    }

    @objc func toggleInfo(_ sender: Any?) {
        if infoTimer != nil {
            infoTimer?.invalidate()
            infoTimer = nil
            view.setInfo(nil)
            return
        }
        _ = conn.takeStats()
        infoAt = CACurrentMediaTime()
        shownAt = view.shown
        infoTimer = Timer.scheduledTimer(timeInterval: 1, target: self, selector: #selector(updateInfo),
                                         userInfo: nil, repeats: true)
        updateInfo()
    }

    /// Stream Info: what reaches the window and how it's shown; the VM's side of it.
    @objc func updateInfo() {
        let now = CACurrentMediaTime(), dt = max(0.001, now - infoAt)
        let st = conn.takeStats()
        let drawn = Double(view.shown - shownAt) / dt
        infoAt = now
        shownAt = view.shown
        let scale = window.backingScaleFactor
        let pic = view.pictureRect()
        let outW = Int((pic.width * scale).rounded()), outH = Int((pic.height * scale).rounded())
        let how = view.renderer.map { $0.mode.isEmpty ? "Metal" : $0.mode } ?? "Core Animation"
        let kb = st.frames > 0 ? Double(st.bytes) / Double(st.frames) / 1024 : 0
        let decode = st.frames > 0 ? st.decodeMs / Double(st.frames) : 0
        let into = st.frames > 0 ? st.drawMs / Double(st.frames) : 0
        var lines = [
            String(format: "Mac:  %.0f updates/s received, %.0f drawn, %.0f KB each, decode %.1f ms (3 at once) + %.1f ms",
                   Double(st.frames) / dt, drawn, kb, decode, into),
            "      VM screen \(view.screenW)×\(view.screenH) shown at \(outW)×\(outH) (\(how)), asking for \(fixedFPS ?? frameRate()) fps",
        ]
        if st.haveServer {
            lines.append(String(format: "VM:   %.0f fps sent, capture %.1f ms, encode %.1f ms, send %.1f ms, %ld sharp stills/s",
                                st.serverFPS, st.captureMs, st.encodeMs, st.sendMs, st.sharp))
        } else {
            lines.append("VM:   no numbers (Steam > Update the VM brings the newer screen server)")
        }
        view.setInfo(lines.joined(separator: "\n"))
    }
}
