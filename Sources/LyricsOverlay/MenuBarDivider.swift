import AppKit
import CoreGraphics

/// Bartender-style hiding of other menu bar icons, with two extra status items
/// left of the lyrics (♪) item:
///
///     [icons to hide] [expander] [‹ toggle] [♪] [system icons]
///
/// While icons are shown the expander is a thin "|" the user can ⌘-drag to choose
/// which icons hide (everything left of it); collapsing it makes it 10,000 pt wide,
/// which pushes every status item to its left off screen. ♪ always stays.
///
/// While icons are hidden ♪ shows the lyric and grows leftwards; on a notched screen a
/// long line pushed the toggle behind the notch, leaving no way to show the icons
/// again. `keepToggleVisible` shortens the menu bar text until the toggle reappears.
///
/// Only the toggle decides: ‹ (icons hidden) / › (icons shown). Playback doesn't.
///
/// Nothing is ever removed from the menu bar (isVisible = false / isInserted = false)
/// except the expander when re-placing it: macOS forgets a removed item's position.
@MainActor
final class MenuBarDividerController: NSObject {
    private let model: LyricsModel
    private var expander: NSStatusItem?
    private var toggle: NSStatusItem?

    static let collapsedLength: CGFloat = 10_000
    private static let expanderName = "LyricsOverlayDivider"
    private static let toggleName = "LyricsOverlayToggle"

    init(model: LyricsModel) {
        self.model = model
        super.init()
        // Wait for the MenuBarExtra item to be laid out so we can measure it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.createItems()
            self?.observe()
        }
    }

    private static func positionKey(_ name: String) -> String { "NSStatusItem Preferred Position \(name)" }

    /// New status items appear left of *all* others, and an item with no stored
    /// position (like the MenuBarExtra's) is put leftmost too. Store preferred
    /// positions — distance from the screen's right edge, larger = further left —
    /// left of ♪: the toggle right next to it, the expander next to the toggle.
    /// Measured only while ♪ is on screen, and stored values are never overwritten;
    /// after that macOS remembers wherever the user ⌘-drags them.
    private func createItems() {
        let d = UserDefaults.standard
        if let window = lyricsItemWindow, let screen = window.screen,
           window.frame.minX > screen.frame.minX + 100,
           let lyricsName = Self.statusItem(of: window)?.autosaveName {
            let lyricsKey = Self.positionKey(lyricsName)
            let lyricsPosition = d.object(forKey: lyricsKey) as? Double
                ?? Double(screen.frame.maxX - window.frame.maxX)
            for (key, value) in [(lyricsKey, lyricsPosition),
                                 (Self.positionKey(Self.expanderName), lyricsPosition + 1),
                                 (Self.positionKey(Self.toggleName), lyricsPosition + 0.5)]
            where d.object(forKey: key) == nil {
                d.set(value, forKey: key)
            }
        }

        expander = Self.makeExpander()

        let toggle = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        toggle.autosaveName = Self.toggleName
        toggle.button?.target = self
        toggle.button?.action = #selector(toggleClicked)
        self.toggle = toggle
    }

    private static func makeExpander() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: 0)
        item.autosaveName = expanderName
        item.button?.isEnabled = false
        item.button?.toolTip = "⌘-drag to choose which icons hide (those left of this line)"
        return item
    }

    private static let dividerImage: NSImage? = {
        let image = NSImage(systemSymbolName: "poweron", accessibilityDescription: "Hidden icons divider")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .bold))
        image?.isTemplate = true
        return image
    }()

    @objc private func toggleClicked() {
        model.iconsHidden.toggle()
    }

    /// The MenuBarExtra's (♪) status item windows; MenuBarExtra doesn't expose the item.
    /// Our own items are told apart by their "LyricsOverlay…" autosave names.
    static func lyricsItemWindows() -> [NSWindow] {
        NSApp.windows.filter { w in
            // autosaveName is implicitly unwrapped and can be nil mid ⌘-drag; reading it
            // directly crashed the app
            let name: String? = statusItem(of: w)?.autosaveName
            return w.className == "NSStatusBarWindow" && !(name?.hasPrefix("LyricsOverlay") ?? false)
        }
    }

    private var lyricsItemWindow: NSWindow? { Self.lyricsItemWindows().first { $0.isVisible } }

    /// The NSStatusItem behind a status bar window, via AppKit's private accessor.
    private static func statusItem(of window: NSWindow) -> NSStatusItem? {
        guard window.responds(to: NSSelectorFromString("statusItem")) else { return nil }
        return window.value(forKey: "statusItem") as? NSStatusItem
    }

    // MARK: Keeping the toggle reachable

    private var visibilityCheck: DispatchWorkItem?

    /// While icons are hidden, re-check every second: the menu bar re-lays out whenever ♪'s
    /// text changes width, and the first collapse can be refused before layout settles.
    private func scheduleVisibilityCheck() {
        visibilityCheck?.cancel()
        guard model.iconHidingEnabled, model.iconsHidden else { return }
        let work = DispatchWorkItem { [weak self] in self?.keepToggleVisible() }
        visibilityCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private func keepToggleVisible() {
        guard let expander, let frame = toggle?.button?.window?.frame else { return }
        // ⌘-dragging the toggle left while collapsed drops it into the hidden part with
        // everything else; show the icons so it comes back where it was dropped.
        if expander.length == Self.collapsedLength, let divider = expander.button?.window?.frame,
           frame.maxX <= divider.minX + 1 {
            log.info("Toggle moved left of the divider; showing icons")
            model.iconsHidden = false
            return
        }
        // ♪ itself can also land behind the notch when its text gets wider
        let lyricsHidden = lyricsItemWindow.map { !Self.isOnScreen($0.frame) } ?? false
        if !Self.isOnScreen(frame) || lyricsHidden {
            let cap = max(Self.minMenuBarLength, (model.menuBarLengthCap ?? model.menuBarLength) - 8)
            if cap != model.menuBarLengthCap {
                log.info("Toggle or ♪ hidden (notch?); menu bar text capped at \(cap) characters")
                model.menuBarLengthCap = cap
            }
        } else if expander.length != Self.collapsedLength {
            update()  // collapse was refused earlier, e.g. before ♪ was laid out
            return
        }
        scheduleVisibilityCheck()
    }

    static let minMenuBarLength = 10

    /// Whether the status item window at `frame` is actually shown. macOS hides items
    /// that would sit under the notch; CGWindowList reports those as off screen. Matched
    /// by frame because on macOS 26 Control Center owns every status item window.
    private static func isOnScreen(_ frame: NSRect) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            return true
        }
        let level = Int(CGWindowLevelForKey(.statusWindow))
        return list.contains { w in
            guard (w[kCGWindowLayer as String] as? Int) == level,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let width = b["Width"] else { return false }
            return abs(x - frame.minX) < 1 && abs(width - frame.width) < 1
                && (w[kCGWindowIsOnscreen as String] as? Bool ?? false)
        }
    }

    // MARK: State

    private func observe() {
        withObservationTracking {
            _ = model.iconHidingEnabled
            _ = model.iconsHidden
        } onChange: { [weak self] in
            // observe() re-registers and runs update() itself.
            Task { @MainActor in self?.observe() }
        }
        update()
    }

    /// ♪ or the toggle can sit left of the expander (first launch, before positions were
    /// stored, or after a ⌘-drag); collapsing then would hide them too, and without the
    /// toggle there is no way back. Checked each time the expander
    /// is about to collapse; an already collapsed one is left alone, since its window
    /// frame is mid-layout (it grows rightwards over ♪ before the bar shifts it left).
    private var canCollapse: Bool {
        guard let expander, let expanderWindow = expander.button?.window, let lyrics = lyricsItemWindow else { return false }
        if expander.length == Self.collapsedLength { return true }
        let edge = expanderWindow.frame.maxX - 1
        let toggleOK = toggle?.button?.window.map { $0.frame.minX >= edge } ?? false
        let ok = lyrics.frame.minX >= edge && toggleOK
        if !ok { log.info("♪ or the toggle is left of the divider; not hiding icons") }
        return ok
    }

    private func update() {
        guard let expander, let toggle else { return }
        let showToggle = model.iconHidingEnabled
        let hidden = model.iconsHidden
        let collapse = showToggle && hidden && canCollapse
        expander.length = collapse ? Self.collapsedLength : (showToggle ? NSStatusItem.variableLength : 0)
        // Visible only while not collapsed, so it can be ⌘-dragged; a 10,000 pt wide
        // item would draw it somewhere in the middle of the bar
        expander.button?.image = showToggle && !collapse ? Self.dividerImage : nil
        if !(showToggle && hidden) { model.menuBarLengthCap = nil }
        scheduleVisibilityCheck()

        toggle.length = showToggle ? NSStatusItem.variableLength : 0
        toggle.button?.isEnabled = showToggle
        let image = showToggle
            ? NSImage(systemSymbolName: hidden ? "chevron.compact.left" : "chevron.compact.right",
                      accessibilityDescription: hidden ? "Show menu bar icons" : "Hide menu bar icons")
            : nil
        image?.isTemplate = true
        toggle.button?.image = image
        toggle.button?.toolTip = showToggle ? (hidden ? "Show hidden menu bar icons" : "Hide menu bar icons") : nil
    }
}
