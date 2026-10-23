import AppKit
import CoreGraphics

/// Bartender-style hiding of other menu bar icons, with two extra status items
/// around the lyrics (♪) item:
///
///     [icons to hide] [expander] [♪] [‹ toggle] [system icons]
///
/// The expander has no image; collapsing it makes it 10,000 pt wide, which pushes
/// every status item to its left off screen. ♪ always stays.
///
/// - Playing: icons hidden, the toggle has no width. Clicking ♪ opens its window and
///   reveals the icons until it closes.
/// - Not playing: ‹ (icons hidden) / › (icons shown) toggles them.
///
/// Nothing is ever removed from the menu bar (isVisible = false / isInserted = false)
/// except the expander when re-placing it: macOS forgets a removed item's position.
@MainActor
final class MenuBarDividerController: NSObject {
    private let model: LyricsModel
    private var expander: NSStatusItem?
    private var toggle: NSStatusItem?
    /// Set once ♪ has been seen right of the expander (see `canCollapse`).
    private var orderVerified = false
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
    /// around ♪: expander just left, toggle just right. Measured only while ♪ is on
    /// screen, and stored values are never overwritten; after that macOS remembers
    /// wherever the user ⌘-drags them.
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
                                 (Self.positionKey(Self.toggleName), lyricsPosition - 1)]
            where d.object(forKey: key) == nil {
                d.set(value, forKey: key)
            }
            model.menuBarPlacementDone = true
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
        model.iconsHiddenWhenIdle.toggle()
    }

    /// The MenuBarExtra's status item window (MenuBarExtra doesn't expose the item).
    private var lyricsItemWindow: NSWindow? {
        let ours = [expander, toggle].compactMap { $0?.button?.window }
        return NSApp.windows.first { w in
            w.className == "NSStatusBarWindow" && w.isVisible && !ours.contains { $0 === w }
        }
    }

    /// The NSStatusItem behind a status bar window, via AppKit's private accessor.
    private static func statusItem(of window: NSWindow) -> NSStatusItem? {
        guard window.responds(to: NSSelectorFromString("statusItem")) else { return nil }
        return window.value(forKey: "statusItem") as? NSStatusItem
    }

    // MARK: Keeping the expander right next to ♪

    /// Apps whose status item has no stored position (YT Music.app, for one) can be
    /// slotted between the expander and ♪, where they'd never hide. If that happens,
    /// move the expander's stored position halfway towards ♪'s and re-add it.
    private func scheduleAdjacencyCheck() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.checkAdjacency() }
    }

    private func checkAdjacency() {
        guard placementAttempts < 6, let expander, let expanderWindow = expander.button?.window,
              let lyrics = lyricsItemWindow, let screen = lyrics.screen,
              let lyricsName = Self.statusItem(of: lyrics)?.autosaveName else { return }
        let gapStart = expanderWindow.frame.maxX, gapEnd = lyrics.frame.minX
        guard gapEnd - gapStart > 2, Self.otherStatusWindows(in: gapStart...gapEnd, screen: screen) else { return }

        let d = UserDefaults.standard
        let lyricsPosition = d.double(forKey: Self.positionKey(lyricsName))
        let current = d.object(forKey: Self.positionKey(Self.expanderName)) as? Double ?? lyricsPosition + 1
        let closer = lyricsPosition + (current - lyricsPosition) / 2
        placementAttempts += 1
        log.info("Icon between divider and ♪; moving divider \(current) → \(closer)")
        NSStatusBar.system.removeStatusItem(expander)
        d.set(closer, forKey: Self.positionKey(Self.expanderName))
        self.expander = Self.makeExpander()
        orderVerified = false
        update()
        scheduleAdjacencyCheck()
    }

    /// Whether another app's status item window (menu bar level) lies within `range`
    /// (AppKit x coordinates). Window bounds need no Screen Recording permission.
    private static func otherStatusWindows(in range: ClosedRange<CGFloat>, screen: NSScreen) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        let ownPID = Int(ProcessInfo.processInfo.processIdentifier)
        return list.contains { w in
            guard (w[kCGWindowLayer as String] as? Int) == Int(CGWindowLevelForKey(.statusWindow)),
                  (w[kCGWindowOwnerPID as String] as? Int) != ownPID,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let width = b["Width"], let y = b["Y"], y < 50 else { return false }
            return x >= range.lowerBound - 1 && x + width <= range.upperBound + 1 && width > 4
        }
    }

    // MARK: State

    private func observe() {
        withObservationTracking {
            _ = model.hideIconsWhilePlaying
            _ = model.isPlaying
            _ = model.isMenuWindowOpen
            _ = model.iconsHiddenWhenIdle
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.update()
                self?.observe()
            }
        }
        update()
    }

    /// On the very first launch the MenuBarExtra item was created before its position
    /// was stored, so it can sit left of the expander until a relaunch; collapsing then
    /// would hide ♪ too.
    private var canCollapse: Bool {
        if orderVerified { return true }
        guard let expanderWindow = expander?.button?.window, let lyrics = lyricsItemWindow else { return false }
        orderVerified = lyrics.frame.minX >= expanderWindow.frame.maxX - 1
        if !orderVerified { log.info("♪ is left of the divider; not hiding icons until relaunch") }
        return orderVerified
    }

    private func update() {
        guard let expander, let toggle else { return }
        let enabled = model.hideIconsWhilePlaying
        let playing = model.isPlaying

        let hide = enabled && (playing ? !model.isMenuWindowOpen : model.iconsHiddenWhenIdle)
        expander.length = hide && canCollapse ? Self.collapsedLength : 0

        // The toggle is only there when nothing is playing; otherwise it takes no space.
        let showToggle = enabled && !playing
        toggle.length = showToggle ? NSStatusItem.variableLength : 0
        toggle.button?.isEnabled = showToggle
        let hidden = model.iconsHiddenWhenIdle
        let image = showToggle
            ? NSImage(systemSymbolName: hidden ? "chevron.compact.left" : "chevron.compact.right",
                      accessibilityDescription: hidden ? "Show menu bar icons" : "Hide menu bar icons")
            : nil
        image?.isTemplate = true
        toggle.button?.image = image
        toggle.button?.toolTip = showToggle ? (hidden ? "Show hidden menu bar icons" : "Hide menu bar icons") : nil
    }
}
