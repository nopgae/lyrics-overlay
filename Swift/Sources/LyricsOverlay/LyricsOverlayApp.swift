import SwiftUI

@main
struct LyricsOverlayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarWindowView()
                .environment(appDelegate.model)
        } label: {
            MenuBarLabel()
                .environment(appDelegate.model)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = LyricsModel()
    private var karaoke: KaraokePanelController?
    private(set) lazy var fullLyrics = FullLyricsWindowController(model: model)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Panels can only be created once NSApp is up, so not in App.init.
        karaoke = KaraokePanelController(model: model)
        model.showFullLyrics = { [weak self] in self?.fullLyrics.show() }
        #if DEBUG
        DebugSnapshot.runIfRequested(model: model, karaoke: karaoke, fullLyrics: fullLyrics)
        #endif
    }
}
