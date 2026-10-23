import LyricsCore
import SwiftUI

/// Floating karaoke strip: the current line fills left→right as it's sung, the
/// next line waits underneath. LRC only times whole lines, so the fill speed is
/// estimated from the line's length (see `fillDuration`).
struct KaraokeView: View {
    @Environment(LyricsModel.self) private var model
    @State private var hovering = false

    static let width: CGFloat = 760

    var body: some View {
        VStack(spacing: 6) {
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !model.isPlaying)) { context in
                KaraokeLine(text: model.currentLine ?? "",
                            progress: progress(at: context.date),
                            fill: fillColor,
                            fontSize: model.karaokeFontSize)
            }
            .id(model.currentIndex)
            .transition(.opacity.combined(with: .offset(y: 6)))

            if let next = model.nextLine, !next.isEmpty {
                Text(next)
                    .font(.system(size: model.karaokeFontSize * 0.55, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .id(model.currentIndex.map { $0 + 1 })
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.25), value: model.currentIndex)
        .padding(.vertical, 14)
        .padding(.horizontal, 28)
        .frame(width: Self.width)
        .background { background }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button { model.showKaraoke = false } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
                .padding(8)
                .help("Hide karaoke")
            }
        }
        .opacity(model.isPlaying ? 1 : 0.6)
        .onHover { hovering = $0 }
        .environment(\.colorScheme, .dark)
    }

    private var background: some View {
        ZStack {
            VisualEffectBlur(material: .hudWindow)
            // Keeps white text readable over bright desktops
            Color.black.opacity(0.35)
            LinearGradient(colors: [Color(nsColor: model.artworkColor ?? .systemIndigo), .clear],
                           startPoint: .leading, endPoint: .trailing)
                .opacity(model.karaokeTint)
        }
    }

    /// Bright tint of the artwork color, so the sung part reads as "lit".
    private var fillColor: Color {
        guard let c = model.artworkColor?.usingColorSpace(.deviceRGB) else { return Color(nsColor: .systemTeal) }
        return Color(nsColor: c.blended(withFraction: 0.65, of: .white) ?? .white)
    }

    private func progress(at date: Date) -> Double {
        guard let idx = model.currentIndex else { return 0 }
        let line = model.lyrics[idx]
        let next = SyncEngine.nextTime(after: idx, in: model.lyrics) ?? line.time + 6
        let elapsed = model.position(at: date) - line.time
        let duration = Self.fillDuration(for: line.text, gap: next - line.time)
        return min(1, max(0, elapsed / duration))
    }

    /// Rough singing time for `text`: CJK/Hangul syllables are sung one per beat,
    /// Latin text goes faster per character. Never longer than the gap to the next line.
    static func fillDuration(for text: String, gap: TimeInterval) -> TimeInterval {
        var t = 0.0
        for scalar in text.unicodeScalars where !CharacterSet.whitespaces.contains(scalar) {
            switch scalar.value {
            case 0xAC00...0xD7A3, 0x3040...0x30FF, 0x4E00...0x9FFF: t += 0.22
            default: t += 0.07
            }
        }
        return max(0.4, min(gap * 0.95, max(1.0, t)))
    }
}

/// One line with a left→right reveal: a dim copy underneath, a lit copy masked to `progress`.
private struct KaraokeLine: View {
    private static let feather: CGFloat = 18

    let text: String
    let progress: Double
    let fill: Color
    let fontSize: CGFloat

    var body: some View {
        let label = Text(text.isEmpty ? "♪" : text)
            .font(.system(size: fontSize, weight: .bold))
            .lineLimit(1)
            .minimumScaleFactor(0.5)
        label
            .foregroundStyle(.white.opacity(0.35))
            .overlay {
                label
                    .foregroundStyle(fill)
                    .mask(alignment: .leading) {
                        // Soft leading edge instead of a hard cut through a glyph
                        GeometryReader { g in
                            HStack(spacing: 0) {
                                Rectangle().frame(width: max(0, g.size.width * progress - Self.feather))
                                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                                    .frame(width: Self.feather)
                            }
                        }
                    }
            }
    }
}

struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
    }
}
