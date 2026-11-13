#if DEBUG
import LyricsCore
import SwiftUI

/// Debug-only: `LYRICS_SNAPSHOT=/path/windowid.txt` shows the menu bar window as a
/// regular on-screen window, writes its window number to that file, and quits after
/// a few seconds, so `screencapture -l <id>` can grab it. `LYRICS_DEMO=1` fills it
/// with a fake track; `LYRICS_DARK=0|1` forces the appearance;
/// `LYRICS_TARGET=karaoke` captures the karaoke panel instead.
enum DebugSnapshot {
    @MainActor
    static func runIfRequested(model: LyricsModel, karaoke: KaraokePanelController?, notch: NotchPanelController?,
                               fullLyrics: FullLyricsWindowController, settings: SettingsWindowController) {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["LYRICS_SNAPSHOT"] else { return }
        if env["LYRICS_DEMO"] == "1" { model.loadDemo() }
        if let tab = env["LYRICS_SETTINGS_TAB"].flatMap(Int.init) {
            UserDefaults.standard.set(tab, forKey: "settingsTab")
            settings.show()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                try? String(settings.window.windowNumber).write(toFile: path, atomically: true, encoding: .utf8)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { exit(0) }
            }
            return
        }
        if env["LYRICS_TARGET"] == "notch", let panel = notch?.panel {
            let saved = model.notchMode
            model.notchMode = .always
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                try? String(panel.windowNumber).write(toFile: path, atomically: true, encoding: .utf8)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    model.notchMode = saved
                    exit(0)
                }
            }
            return
        }
        if env["LYRICS_TARGET"] == "full" {
            fullLyrics.show()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                try? String(fullLyrics.window.windowNumber).write(toFile: path, atomically: true, encoding: .utf8)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { exit(0) }
            }
            return
        }
        if env["LYRICS_TARGET"] == "karaoke", let panel = karaoke?.panel {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                try? String(panel.windowNumber).write(toFile: path, atomically: true, encoding: .utf8)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { exit(0) }
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let host = NSHostingView(rootView: MenuBarWindowView().environment(model))
            let size = host.fittingSize
            let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: size.width, height: size.height),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            if let dark = env["LYRICS_DARK"] {
                window.appearance = NSAppearance(named: dark == "1" ? .darkAqua : .aqua)
            }
            // Same material the real MenuBarExtra window uses
            let blur = NSVisualEffectView()
            blur.material = .popover
            blur.state = .active
            blur.blendingMode = .behindWindow
            host.translatesAutoresizingMaskIntoConstraints = false
            blur.addSubview(host)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
                host.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
                host.topAnchor.constraint(equalTo: blur.topAnchor),
                host.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
            ])
            window.contentView = blur
            window.level = .floating
            window.orderFrontRegardless()
            try? String(window.windowNumber).write(toFile: path, atomically: true, encoding: .utf8)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { exit(0) }
        }
    }
}

extension LyricsModel {
    func loadDemo() {
        debugSet(
            snapshot: PlaybackSnapshot(source: .youtubeMusic, title: "Night Drive", artist: "Demo Artist", album: "",
                                       position: 27.0, duration: 179, isPaused: false, fetchedAt: Date(), artworkURL: nil),
            // Original placeholder lines, not a real song, so the screenshots can be published
            lyrics: [LyricLine(time: 14, text: "창밖으로 번지는 불빛"),
                     LyricLine(time: 17, text: "City lights are passing by"),
                     LyricLine(time: 21, text: "라디오를 조금 더 크게"),
                     LyricLine(time: 24, text: "We don't need to say a word"),
                     LyricLine(time: 28, text: "Every line falls into time"),
                     LyricLine(time: 31, text: "가사가 박자에 맞춰 흘러"),
                     LyricLine(time: 34, text: "Keep on rolling through the night"),
                     LyricLine(time: 38, text: "끝나지 않는 이 도로 위"),
                     LyricLine(time: 41, text: "Hold the moment, hold it tight"),
                     LyricLine(time: 44, text: "아침이 올 때까지")],
            status: "LRCLIB · 51 lines",
            artworkColor: NSColor(red: 0.45, green: 0.62, blue: 0.85, alpha: 1),
            palette: [(0.20, 0.32, 0.52), (0.30, 0.45, 0.60), (0.42, 0.50, 0.58),
                      (0.18, 0.28, 0.45), (0.35, 0.40, 0.55), (0.48, 0.42, 0.50),
                      (0.12, 0.18, 0.32), (0.22, 0.26, 0.40), (0.30, 0.28, 0.38)]
                .map { NSColor(red: $0.0, green: $0.1, blue: $0.2, alpha: 1) }
        )
    }
}
#endif
