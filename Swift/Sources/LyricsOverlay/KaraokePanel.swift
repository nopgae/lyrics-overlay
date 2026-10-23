import AppKit
import SwiftUI

/// Borderless floating panel hosting `KaraokeView`. Never takes focus, follows you
/// across Spaces and over full-screen apps, and remembers where you dragged it.
final class KaraokePanel: NSPanel {
    init(model: LyricsModel) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: KaraokeView.width, height: 110),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false

        let host = NSHostingView(rootView: KaraokeView().environment(model))
        host.sizingOptions = [.intrinsicContentSize]
        contentView = host
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Shows/hides the karaoke panel as playback and the setting change.
@MainActor
final class KaraokePanelController {
    private let model: LyricsModel
    let panel: KaraokePanel
    private var mouseUpMonitor: Any?
    private var visible = false

    private static let snapDistance: CGFloat = 30

    init(model: LyricsModel) {
        self.model = model
        panel = KaraokePanel(model: model)
        restorePosition()
        // Snap to horizontal centre and save the spot when a drag ends.
        mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            if event.window === self?.panel { self?.dragEnded() }
            return event
        }
        observe()
    }

    var shouldShow: Bool { model.showKaraoke && model.snapshot != nil }

    private func observe() {
        withObservationTracking {
            _ = shouldShow
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.update()
                self?.observe()
            }
        }
        update()
    }

    private func update() {
        guard shouldShow != visible else { return }
        visible = shouldShow
        if visible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.25; panel.animator().alphaValue = 1 }
        } else {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; panel.animator().alphaValue = 0 },
                                                 completionHandler: { [panel] in panel.orderOut(nil) })
        }
    }

    private func restorePosition() {
        let d = UserDefaults.standard
        if let x = d.object(forKey: "karaokeX") as? Double, let y = d.object(forKey: "karaokeY") as? Double,
           NSScreen.screens.contains(where: { $0.visibleFrame.contains(NSPoint(x: x + KaraokeView.width / 2, y: y + 40)) }) {
            panel.setFrameOrigin(NSPoint(x: x, y: y))
            return
        }
        guard let screen = NSScreen.main?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: screen.midX - KaraokeView.width / 2, y: screen.minY + 80))
    }

    private func dragEnded() {
        var origin = panel.frame.origin
        if let screen = panel.screen?.visibleFrame,
           abs(panel.frame.midX - screen.midX) < Self.snapDistance {
            origin.x = screen.midX - panel.frame.width / 2
            panel.animator().setFrameOrigin(origin)
        }
        UserDefaults.standard.set(origin.x, forKey: "karaokeX")
        UserDefaults.standard.set(origin.y, forKey: "karaokeY")
    }
}
