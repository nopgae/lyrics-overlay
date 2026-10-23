import AppKit
import SwiftUI

enum NotchMode: String, CaseIterable, Identifiable {
    case off
    case auto     // only when the menu bar item is hidden (e.g. pushed under the notch)
    case always

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "Off"
        case .auto: "When the menu bar icon is hidden"
        case .always: "Always"
        }
    }
}

/// Geometry of the camera notch on a screen (zero width when there is none).
struct NotchGeometry: Equatable {
    var centerX: CGFloat        // screen coordinates
    var width: CGFloat
    var height: CGFloat         // menu bar height on that screen
    var screenTop: CGFloat

    init(screen: NSScreen) {
        let f = screen.frame
        screenTop = f.maxY
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            width = right.minX - left.maxX
            centerX = left.maxX + width / 2
            height = screen.safeAreaInsets.top
        } else {
            width = 0
            centerX = f.midX
            height = NSStatusBar.system.thickness
        }
    }
}

/// Black shape that continues the notch downward into a pill holding one lyric line.
struct NotchShape: Shape {
    var notchWidth: CGFloat
    var notchHeight: CGFloat
    var radius: CGFloat = 12

    var animatableData: CGFloat {
        get { notchWidth }
        set { notchWidth = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r = radius
        let top = max(r, notchWidth)  // width of the part that sits behind the notch
        let topL = rect.midX - top / 2, topR = rect.midX + top / 2
        p.move(to: CGPoint(x: topL, y: 0))
        p.addLine(to: CGPoint(x: topR, y: 0))
        p.addLine(to: CGPoint(x: topR, y: notchHeight - r))
        // Flare out from the notch to the pill's full width
        p.addQuadCurve(to: CGPoint(x: min(rect.maxX, topR + r), y: notchHeight),
                       control: CGPoint(x: topR, y: notchHeight))
        p.addLine(to: CGPoint(x: rect.maxX - r, y: notchHeight))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: notchHeight + r), control: CGPoint(x: rect.maxX, y: notchHeight))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r), control: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: notchHeight + r))
        p.addQuadCurve(to: CGPoint(x: rect.minX + r, y: notchHeight), control: CGPoint(x: rect.minX, y: notchHeight))
        p.addLine(to: CGPoint(x: max(rect.minX, topL - r), y: notchHeight))
        p.addQuadCurve(to: CGPoint(x: topL, y: notchHeight - r), control: CGPoint(x: topL, y: notchHeight))
        p.closeSubpath()
        return p
    }
}

struct NotchLyricView: View {
    @Environment(LyricsModel.self) private var model
    let geometry: NotchGeometry
    static let maxWidth: CGFloat = 520
    static let lineHeight: CGFloat = 30

    private var text: String {
        if let line = model.currentLine, !line.isEmpty { return line }
        guard let s = model.snapshot else { return "" }
        return s.artist.isEmpty ? "♪ \(s.title)" : "♪ \(s.title) — \(s.artist)"
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: geometry.height)
            Text(text)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .id(text)
                .transition(.opacity)
                .frame(height: Self.lineHeight)
                .padding(.horizontal, 22)
        }
        .frame(minWidth: geometry.width + 24, maxWidth: Self.maxWidth)
        .fixedSize(horizontal: true, vertical: false)
        .background(NotchShape(notchWidth: geometry.width, notchHeight: geometry.height).fill(.black))
        .animation(.easeInOut(duration: 0.25), value: text)
        .contentShape(NotchShape(notchWidth: geometry.width, notchHeight: geometry.height))
        .onTapGesture { model.showFullLyrics() }
        .help("Open lyrics")
        .frame(width: Self.maxWidth, alignment: .top)  // panel is fixed; the shape sizes to the text
    }
}

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Shows the lyric under the notch when the menu bar item can't be seen (or always,
/// per the setting).
@MainActor
final class NotchPanelController {
    private let model: LyricsModel
    let panel: NotchPanel
    private var geometry: NotchGeometry?
    private var statusItemHidden = false
    private var visible = false
    private var checkTimer: Timer?

    init(model: LyricsModel) {
        self.model = model
        panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: true)
        panel.level = .statusBar + 1
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        }
        // The menu bar rearranges itself as apps come and go; re-check now and then.
        checkTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkStatusItem() }
        }
        layout()
        observe()
    }

    private func observe() {
        withObservationTracking {
            _ = model.notchMode
            _ = model.snapshot == nil
            _ = model.isMenuBarItemInserted
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.update()
                self?.observe()
            }
        }
        update()
    }

    private func layout() {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return }
        let g = NotchGeometry(screen: screen)
        geometry = g
        let height = g.height + NotchLyricView.lineHeight
        panel.setFrame(NSRect(x: g.centerX - NotchLyricView.maxWidth / 2, y: g.screenTop - height,
                              width: NotchLyricView.maxWidth, height: height), display: false)
        panel.contentView = NSHostingView(rootView: NotchLyricView(geometry: g).environment(model))
        checkStatusItem()
    }

    /// MenuBarExtra doesn't expose its NSStatusItem; find its window instead. When
    /// macOS has no room for it (e.g. behind the notch) the window is off screen.
    private func checkStatusItem() {
        let windows = NSApp.windows.filter { $0.className == "NSStatusBarWindow" }
        let hidden = windows.isEmpty || windows.allSatisfy { w in
            w.screen == nil || w.frame.maxX <= 0 || !w.occlusionState.contains(.visible)
        }
        if hidden != statusItemHidden {
            statusItemHidden = hidden
            log.info("Menu bar item hidden: \(hidden), frames: \(windows.map { NSStringFromRect($0.frame) }, privacy: .public)")
            update()
        }
    }

    private func update() {
        let show: Bool
        switch model.notchMode {
        case .off: show = false
        // (♪ hidden on purpose by the ‹ toggle doesn't count.)
        case .auto: show = statusItemHidden && model.snapshot != nil && model.isMenuBarItemInserted
        case .always: show = model.snapshot != nil
        }
        guard show != visible else { return }
        visible = show
        if show {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.25; panel.animator().alphaValue = 1 }
        } else {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; panel.animator().alphaValue = 0 },
                                                 completionHandler: { [panel] in panel.orderOut(nil) })
        }
    }
}
