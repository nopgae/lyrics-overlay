import SwiftUI

@main
struct LyricsOverlayApp: App {
    @State private var model = LyricsModel()

    init() {
        #if DEBUG
        DebugSnapshot.runIfRequested(model: model)
        #endif
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarWindowView()
                .environment(model)
        } label: {
            MenuBarLabel()
                .environment(model)
        }
        .menuBarExtraStyle(.window)
    }
}
