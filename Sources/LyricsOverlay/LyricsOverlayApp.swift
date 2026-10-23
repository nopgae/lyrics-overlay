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
    private var notch: NotchPanelController?
    private var divider: MenuBarDividerController?
    private(set) lazy var fullLyrics = FullLyricsWindowController(model: model)
    private lazy var settings = SettingsWindowController(model: model)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Panels can only be created once NSApp is up, so not in App.init.
        karaoke = KaraokePanelController(model: model)
        notch = NotchPanelController(model: model)
        divider = MenuBarDividerController(model: model)
        model.showFullLyrics = { [weak self] in self?.fullLyrics.show() }
        model.toggleFullLyrics = { [weak self] in self?.fullLyrics.toggle() }
        model.showSettings = { [weak self] in self?.settings.show() }
        model.resetKaraokePosition = { [weak self] in self?.karaoke?.moveToDefaultPosition() }
        #if DEBUG
        DebugSnapshot.runIfRequested(model: model, karaoke: karaoke, notch: notch,
                                     fullLyrics: fullLyrics, settings: settings)
        #endif
    }
}
