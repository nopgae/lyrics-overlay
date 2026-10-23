import SwiftUI

/// Status item content. MenuBarExtra only renders plain Text/Image here.
struct MenuBarLabel: View {
    @Environment(LyricsModel.self) private var model

    var body: some View {
        if let title = model.menuBarTitle {
            Text(title)
        } else {
            Image(systemName: "music.note")
        }
    }
}
