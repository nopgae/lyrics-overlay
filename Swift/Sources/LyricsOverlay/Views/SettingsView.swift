import ServiceManagement
import SwiftUI

struct SettingsView: View {
    /// Reopens on the tab you last used.
    @AppStorage("settingsTab") private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }.tag(0)
            KaraokeSettings().tabItem { Label("Karaoke", systemImage: "dock.rectangle") }.tag(1)
            SyncSettings().tabItem { Label("Sync", systemImage: "timer") }.tag(2)
            AboutView().tabItem { Label("About", systemImage: "info.circle") }.tag(3)
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct GeneralSettings: View {
    @Environment(LyricsModel.self) private var model
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        @Bindable var model = model
        Form {
            Picker("Music player", selection: $model.sourceOverride) {
                Text("Auto-detect").tag(SourceID?.none)
                ForEach(SourceID.allCases) { Text($0.displayName).tag(SourceID?.some($0)) }
            }
            Toggle("Show lyrics in the menu bar", isOn: $model.showLyricsInMenuBar)
            LabeledContent("Menu bar length") {
                HStack {
                    Slider(value: Binding(get: { Double(model.menuBarLength) },
                                          set: { model.menuBarLength = Int(($0 / 5).rounded() * 5) }),
                           in: 20...80)
                    Text("\(model.menuBarLength) characters")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 90, alignment: .trailing)
                }
            }
            .disabled(!model.showLyricsInMenuBar)
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
            if let loginError {
                Text(loginError).font(.caption).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Couldn't change login item: \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

private struct KaraokeSettings: View {
    @Environment(LyricsModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Toggle("Show karaoke strip", isOn: $model.showKaraoke)
            Group {
                LabeledContent("Font size") {
                    HStack {
                        Slider(value: Binding(get: { Double(model.karaokeFontSize) },
                                              set: { model.karaokeFontSize = CGFloat($0.rounded()) }),
                               in: 18...48)
                        Text("\(Int(model.karaokeFontSize)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 50, alignment: .trailing)
                    }
                }
                LabeledContent("Album color tint") {
                    HStack {
                        Slider(value: $model.karaokeTint, in: 0...1)
                        Text("\(Int(model.karaokeTint * 100))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 50, alignment: .trailing)
                    }
                }
                LabeledContent("Position") {
                    Button("Move to Bottom Centre") { model.resetKaraokePosition() }
                }
            }
            .disabled(!model.showKaraoke)
            Text("Drag the strip to move it. Dropped near the middle of the screen, it snaps to the centre.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

private struct SyncSettings: View {
    @Environment(LyricsModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            LabeledContent("Lyric delay") {
                HStack {
                    Slider(value: Binding(get: { model.lyricOffset },
                                          set: { model.lyricOffset = ($0 * 10).rounded() / 10 }),
                           in: -3...3)
                    Text(String(format: "%+.1f s", model.lyricOffset))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 50, alignment: .trailing)
                    Button("Reset") { model.lyricOffset = LyricsModel.defaultLyricOffset }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Raise the delay if lyrics appear before you hear them.")
                Text("Typical: built-in +0.2 s · Bluetooth +0.3–0.5 s · AirPlay ≈ +2 s")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

private struct AboutView: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
            Text("Lyrics Overlay").font(.title2.bold())
            Text("Version \(version)").foregroundStyle(.secondary)
            Divider().padding(.vertical, 4)
            VStack(spacing: 4) {
                Text("Lyrics from [LRCLIB](https://lrclib.net) and NetEase Cloud Music.")
                Text("Interface inspired by [Lyric Fever](https://github.com/aviwad/LyricFever) (MIT).")
                Text("[github.com/nopgae/lyrics-overlay](https://github.com/nopgae/lyrics-overlay)")
            }
            .font(.callout)
            .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}
