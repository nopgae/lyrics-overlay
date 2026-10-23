import SwiftUI

/// Window shown when the status item is clicked: now playing, transport,
/// current lyric, and quick settings.
struct MenuBarWindowView: View {
    @Environment(LyricsModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 14) {
            NowPlayingHeader()
            TransportControls()
            LyricPreview()

            HStack(spacing: 8) {
                ToggleTile(title: "Menu Bar", systemImage: "text.quote", isOn: model.showLyricsInMenuBar) {
                    model.showLyricsInMenuBar.toggle()
                }
                ToggleTile(title: "Karaoke", systemImage: "dock.rectangle", isOn: model.showKaraoke) {
                    model.showKaraoke.toggle()
                }
                ToggleTile(title: "Refresh", systemImage: "arrow.clockwise", isOn: false,
                           isEnabled: model.snapshot != nil && !model.isFetchingLyrics) {
                    model.refetchLyrics()
                }
            }

            Divider()

            VStack(spacing: 10) {
                SliderRow(systemImage: "timer", value: $model.lyricOffset, range: -2...2, step: 0.1,
                          label: String(format: "%+.1fs", model.lyricOffset),
                          help: "Lyric delay — raise it if lyrics appear before you hear them") {
                    model.lyricOffset = LyricsModel.defaultLyricOffset
                }
                SliderRow(systemImage: "textformat.size",
                          value: Binding(get: { Double(model.menuBarLength) },
                                         set: { model.menuBarLength = Int($0) }),
                          range: 20...80, step: 5,
                          label: "\(model.menuBarLength)",
                          help: "Characters shown in the menu bar")

                Picker("Player", selection: $model.sourceOverride) {
                    Text("Auto").tag(SourceID?.none)
                    ForEach(SourceID.allCases) { Text($0.shortName).tag(SourceID?.some($0)) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Divider()

            HStack {
                if model.snapshot != nil {
                    Text(model.lyricsStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.borderless)
                    .keyboardShortcut("q")
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}

private struct NowPlayingHeader: View {
    @Environment(LyricsModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let art = model.artwork {
                    Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        Rectangle().fill(.quaternary)
                        Image(systemName: "music.note").font(.title2).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 4, y: 2)

            VStack(alignment: .leading, spacing: 3) {
                if let s = model.snapshot {
                    Text(s.title).font(.headline).lineLimit(1)
                    Text(s.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    Label(s.isPaused ? "Paused · \(s.source.displayName)" : s.source.displayName,
                          systemImage: s.isPaused ? "pause.circle" : "waveform")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("Not Playing").font(.headline)
                    Text("Play something in Music, Spotify or YouTube Music")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct TransportControls: View {
    @Environment(LyricsModel.self) private var model

    var body: some View {
        HStack(spacing: 36) {
            TransportButton(systemImage: "backward.fill", size: 18) { model.previous() }
            TransportButton(systemImage: model.isPlaying ? "pause.fill" : "play.fill", size: 26) { model.playPause() }
            TransportButton(systemImage: "forward.fill", size: 18) { model.next() }
        }
        .disabled(model.snapshot == nil)
    }
}

private struct TransportButton: View {
    let systemImage: String
    let size: CGFloat
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size))
                .frame(width: 44, height: 36)
                .background(Circle().fill(.primary.opacity(hovering ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct LyricPreview: View {
    @Environment(LyricsModel.self) private var model

    var body: some View {
        VStack(spacing: 4) {
            Text(model.currentLine.flatMap { $0.isEmpty ? nil : $0 } ?? "♪")
                .font(.system(size: 15, weight: .semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .contentTransition(.opacity)
            if let next = model.nextLine, !next.isEmpty {
                Text(next)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 58)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.6)))
        .animation(.easeInOut(duration: 0.25), value: model.currentIndex)
        .opacity(model.snapshot == nil ? 0.5 : 1)
    }
}

/// Square-ish tile button that fills with the accent color when on.
private struct ToggleTile: View {
    let title: String
    let systemImage: String
    let isOn: Bool
    var isEnabled = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: systemImage).font(.system(size: 16))
                Text(title).font(.caption)
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .foregroundStyle(isOn ? Color.white : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary.opacity(hovering ? 0.12 : 0.07)))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { hovering = $0 }
    }
}

private struct SliderRow: View {
    let systemImage: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let label: String
    let help: String
    var reset: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Slider(value: Binding(get: { value },
                                  set: { value = ($0 / step).rounded() * step }),
                   in: range)
                .controlSize(.small)
            Text(label)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
            if let reset {
                Button(action: reset) { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.borderless)
                    .help("Reset")
            }
        }
        .help(help)
    }
}
