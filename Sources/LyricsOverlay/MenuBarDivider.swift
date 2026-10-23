import AppKit
import CoreGraphics

/// Bartender-style hiding of other menu bar icons, with two extra status items
/// left of the lyrics (♪) item:
///
///     [icons to hide] [expander] [‹ toggle] [♪] [system icons]
///
/// The expander has no image; collapsing it makes it 10,000 pt wide, which pushes
/// every status item to its left off screen. ♪ always stays.
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
    private var placementAttempts = 0

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
            self?.scheduleAdjacencyCheck()
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
        return item
    }

    @objc private func toggleClicked() {
        model.iconsHidden.toggle()
    }

    /// The MenuBarExtra's (♪) status item windows; MenuBarExtra doesn't expose the item.
    /// Our own items are told apart by their "LyricsOverlay…" autosave names.
    static func lyricsItemWindows() -> [NSWindow] {
        NSApp.windows.filter { w in
            w.className == "NSStatusBarWindow"
                && !(statusItem(of: w)?.autosaveName.hasPrefix("LyricsOverlay") ?? false)
        }
    }

    private var lyricsItemWindow: NSWindow? { Self.lyricsItemWindows().first { $0.isVisible } }

    /// The NSStatusItem behind a status bar window, via AppKit's private accessor.
    private static func statusItem(of window: NSWindow) -> NSStatusItem? {
        guard window.responds(to: NSSelectorFromString("statusItem")) else { return nil }
        return window.value(forKey: "statusItem") as? NSStatusItem
    }

    // MARK: Keeping the expander right next to ♪

    /// Apps whose status item has no stored position (YT Music.app, for one) can be
    /// slotted between the expander and ♪, where they'd never hide. If that happens,
    /// move the expander's stored position halfway towards the toggle's (its right
    /// neighbour) and re-add it.
    private func scheduleAdjacencyCheck() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.checkAdjacency() }
    }

    private func checkAdjacency() {
        guard placementAttempts < 6, let expander, let expanderWindow = expander.button?.window,
              let lyrics = lyricsItemWindow, let screen = lyrics.screen,
              let lyricsName = Self.statusItem(of: lyrics)?.autosaveName else { return }
        let gapStart = expanderWindow.frame.maxX, gapEnd = lyrics.frame.minX
        let ours = [toggle?.button?.window?.frame].compactMap { $0 }
        guard gapEnd - gapStart > 2,
              Self.otherStatusWindows(in: gapStart...gapEnd, excluding: ours, screen: screen) else { return }

        let d = UserDefaults.standard
        let lyricsPosition = d.double(forKey: Self.positionKey(lyricsName))
        let anchor = d.object(forKey: Self.positionKey(Self.toggleName)) as? Double ?? lyricsPosition
        let current = d.object(forKey: Self.positionKey(Self.expanderName)) as? Double ?? anchor + 1
        let closer = anchor + (current - anchor) / 2
        placementAttempts += 1
        log.info("Icon between divider and ♪; moving divider \(current) → \(closer)")
        NSStatusBar.system.removeStatusItem(expander)
        d.set(closer, forKey: Self.positionKey(Self.expanderName))
        self.expander = Self.makeExpander()
        update()
        scheduleAdjacencyCheck()
    }

    /// Whether another status item window (menu bar level) lies within `range` (AppKit
    /// x coordinates). On macOS 26 every status item window is owned by Control Center,
    /// so our own (`excluding`) are told apart by frame. Bounds need no Screen
    /// Recording permission.
    private static func otherStatusWindows(in range: ClosedRange<CGFloat>, excluding ours: [NSRect],
                                           screen: NSScreen) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        return list.contains { w in
            guard (w[kCGWindowLayer as String] as? Int) == Int(CGWindowLevelForKey(.statusWindow)),
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let width = b["Width"], let y = b["Y"], y < 50, width > 4 else { return false }
            let isOurs = ours.contains { abs($0.minX - x) < 1 && abs($0.width - width) < 1 }
            return !isOurs && x >= range.lowerBound - 1 && x + width <= range.upperBound + 1
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

    /// ♪ can sit left of the expander (first launch, before its position was stored, or
    /// after a ⌘-drag); collapsing then would hide ♪ too. Checked each time the expander
    /// is about to collapse; an already collapsed one is left alone, since its window
    /// frame is mid-layout (it grows rightwards over ♪ before the bar shifts it left).
    private var canCollapse: Bool {
        guard let expander, let expanderWindow = expander.button?.window, let lyrics = lyricsItemWindow else { return false }
        if expander.length == Self.collapsedLength { return true }
        let ok = lyrics.frame.minX >= expanderWindow.frame.maxX - 1
        if !ok { log.info("♪ is left of the divider; not hiding icons") }
        return ok
    }

    private func update() {
        guard let expander, let toggle else { return }
        let showToggle = model.iconHidingEnabled
        let hidden = model.iconsHidden
        expander.length = showToggle && hidden && canCollapse ? Self.collapsedLength : 0

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
