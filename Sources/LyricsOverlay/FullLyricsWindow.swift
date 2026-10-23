import AppKit
import SwiftUI

/// Regular window (resizable, can go full screen) hosting `FullLyricsView`.
@MainActor
final class FullLyricsWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow
    private let model: LyricsModel

    init(model: LyricsModel) {
        self.model = model
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: true)
        super.init()
        window.title = "Lyrics"
        window.appearance = NSAppearance(named: .darkAqua)  // background is always dark
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.fullScreenPrimary]
        window.minSize = NSSize(width: 480, height: 420)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: FullLyricsView().environment(model))
        window.setFrameAutosaveName("FullLyricsWindow")
        window.delegate = self
        if !window.setFrameUsingName("FullLyricsWindow") { window.center() }
    }

    func show() {
        // Menu bar (LSUIElement) apps must activate themselves to bring a window forward.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
    }
}
