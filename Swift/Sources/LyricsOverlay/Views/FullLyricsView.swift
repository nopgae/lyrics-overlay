import LyricsCore
import SwiftUI
import UniformTypeIdentifiers

/// Full-window lyrics: moving artwork-colored background, now playing on the left,
/// scrolling lyrics on the right. Click a line to jump there.
struct FullLyricsView: View {
    @Environment(LyricsModel.self) private var model

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width > 860
            HStack(spacing: wide ? 56 : 0) {
                if wide {
                    NowPlayingColumn()
                        .frame(width: min(340, geo.size.width * 0.32))
                }
                LyricsColumn()
            }
            .padding(.horizontal, wide ? 64 : 32)
            .padding(.top, 40)  // clear the transparent title bar
        }
        .background { MeshBackground(palette: model.artworkPalette) }
        .environment(\.colorScheme, .dark)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { u in
                LocalFilePlayer.audioTypes.contains { UTType(filenameExtension: u.pathExtension)?.conforms(to: $0) == true }
            }) else { return false }
            model.openFile(url)
            return true
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.space) {
            model.playPause()
            return .handled
        }
    }
}

private struct NowPlayingColumn: View {
    @Environment(LyricsModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer()
            Group {
                if let art = model.artwork {
                    Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        Rectangle().fill(.white.opacity(0.08))
                        Image(systemName: "music.note").font(.system(size: 64)).foregroundStyle(.white.opacity(0.4))
                    }
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 24, y: 12)

            VStack(alignment: .leading, spacing: 4) {
                Text(model.snapshot?.title ?? "Not Playing")
                    .font(.system(size: 22, weight: .bold))
                    .lineLimit(2)
                Text(model.snapshot?.artist ?? "")
                    .font(.system(size: 17))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)

            ProgressBar()

            HStack(spacing: 40) {
                Spacer()
                IconButton(systemImage: "backward.fill", size: 22) { model.previous() }
                IconButton(systemImage: model.isPlaying ? "pause.fill" : "play.fill", size: 34) { model.playPause() }
                IconButton(systemImage: "forward.fill", size: 22) { model.next() }
                Spacer()
            }
            .disabled(model.snapshot == nil)
            Spacer()
        }
    }
}

private struct ProgressBar: View {
    @Environment(LyricsModel.self) private var model

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let duration = model.snapshot?.duration ?? 0
            // position() has the lyric delay subtracted; show the raw playback time here
            let pos = min(duration, model.position(at: context.date) + model.lyricOffset)
            VStack(spacing: 6) {
                GeometryReader { g in
                    Capsule().fill(.white.opacity(0.18))
                        .overlay(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.8))
                                .frame(width: duration > 0 ? g.size.width * pos / duration : 0)
                        }
                }
                .frame(height: 5)
                HStack {
                    Text(Self.format(pos))
                    Spacer()
                    Text("-" + Self.format(max(0, duration - pos)))
                }
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.white.opacity(0.55))
            }
        }
        .opacity(model.snapshot == nil ? 0 : 1)
    }

    static func format(_ t: TimeInterval) -> String {
        let s = Int(t.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct LyricsColumn: View {
    @Environment(LyricsModel.self) private var model

    var body: some View {
        if model.lyrics.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: model.isFetchingLyrics ? "ellipsis" : "text.quote")
                    .font(.system(size: 36))
                    .symbolEffect(.variableColor.iterative, isActive: model.isFetchingLyrics)
                Text(model.snapshot == nil ? "Play something to see lyrics" :
                     model.isFetchingLyrics ? "Searching for lyrics…" : "No lyrics found")
                    .font(.title3)
            }
            .foregroundStyle(.white.opacity(0.6))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        // Lets the first and last lines reach the vertical centre
                        Color.clear.frame(height: 220)
                        ForEach(Array(model.lyrics.enumerated()), id: \.offset) { i, line in
                            LyricRow(line: line, distance: model.currentIndex.map { abs($0 - i) } ?? 3)
                                .id(i)
                        }
                        Color.clear.frame(height: 320)
                    }
                    .padding(.trailing, 24)
                }
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.12),
                                             .init(color: .black, location: 0.85), .init(color: .clear, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
                .onChange(of: model.currentIndex, initial: true) { _, idx in
                    guard let idx else { return }
                    withAnimation(.spring(duration: 0.6)) { proxy.scrollTo(idx, anchor: UnitPoint(x: 0, y: 0.38)) }
                }
            }
        }
    }
}

private struct LyricRow: View {
    @Environment(LyricsModel.self) private var model
    let line: LyricLine
    /// Lines away from the current one (0 = current)
    let distance: Int
    @State private var hovering = false

    var body: some View {
        let isCurrent = distance == 0
        Text(line.text.isEmpty ? "♪" : line.text)
            .font(.system(size: 30, weight: .bold))
            .foregroundStyle(.white.opacity(isCurrent ? 1 : hovering ? 0.7 : 0.35))
            .blur(radius: isCurrent || hovering ? 0 : min(Double(distance), 4) * 0.5)
            .scaleEffect(isCurrent ? 1 : 0.94, anchor: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            .padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(hovering && canSeek ? 0.08 : 0)))
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.35), value: distance)
            .onHover { hovering = $0 }
            .onTapGesture {
                // The model shows a line once position − delay passes its time, so seek past it by the delay.
                if canSeek { model.seek(to: line.time + model.lyricOffset + 0.05) }
            }
            .help(canSeek ? "Play from here" : "")
    }

    private var canSeek: Bool { model.lyricsAreSynced && model.snapshot != nil }
}

private struct IconButton: View {
    let systemImage: String
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size))
                .foregroundStyle(.white)
                .frame(width: size * 1.8, height: size * 1.6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Slowly drifting 3×3 mesh of the artwork's region colors (plain gradient before macOS 15).
private struct MeshBackground: View {
    let palette: [NSColor]

    private var colors: [Color] {
        let base = palette.count == 9 ? palette : Self.fallback
        return base.map { Color(nsColor: $0) }
    }

    private static let fallback: [NSColor] = [
        .init(red: 0.16, green: 0.12, blue: 0.32, alpha: 1), .init(red: 0.24, green: 0.14, blue: 0.40, alpha: 1), .init(red: 0.12, green: 0.18, blue: 0.36, alpha: 1),
        .init(red: 0.20, green: 0.10, blue: 0.30, alpha: 1), .init(red: 0.30, green: 0.16, blue: 0.42, alpha: 1), .init(red: 0.14, green: 0.20, blue: 0.40, alpha: 1),
        .init(red: 0.10, green: 0.08, blue: 0.22, alpha: 1), .init(red: 0.18, green: 0.12, blue: 0.30, alpha: 1), .init(red: 0.08, green: 0.12, blue: 0.26, alpha: 1),
    ]

    var body: some View {
        ZStack {
            if #available(macOS 15.0, *) {
                TimelineView(.animation(minimumInterval: 1 / 20)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    MeshGradient(width: 3, height: 3, points: Self.points(t), colors: colors)
                }
            } else {
                LinearGradient(colors: [colors[0], colors[4], colors[8]], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            Color.black.opacity(0.18)
        }
        .animation(.easeInOut(duration: 1.2), value: palette.count)
        .ignoresSafeArea()
    }

    /// Edge points slide along their edge, the centre wanders; corners stay put.
    @available(macOS 15.0, *)
    static func points(_ t: Double) -> [SIMD2<Float>] {
        func w(_ speed: Double, _ phase: Double, _ amp: Double) -> Float { Float(sin(t * speed + phase) * amp) }
        return [
            [0, 0], [0.5 + w(0.21, 0, 0.2), 0], [1, 0],
            [0, 0.5 + w(0.17, 1, 0.2)], [0.5 + w(0.23, 2, 0.15), 0.5 + w(0.19, 3, 0.15)], [1, 0.5 + w(0.25, 4, 0.2)],
            [0, 1], [0.5 + w(0.15, 5, 0.2), 1], [1, 1],
        ]
    }
}
