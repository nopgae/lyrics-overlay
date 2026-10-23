import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    let window: NSWindow

    init(model: LyricsModel) {
        window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable],
                          backing: .buffered, defer: true)
        window.title = "Lyrics Overlay Settings"
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: SettingsView().environment(model))
        host.sizingOptions = [.preferredContentSize]
        window.contentView = host
        window.center()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
