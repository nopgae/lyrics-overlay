import AppKit

/// Bartender-style hiding of other menu bar icons, with three extra status items
/// around the lyrics (♪) item:
///
///     [icons to hide] [outer] [♪] [inner] [‹ toggle] [system icons]
///
/// Expanders have no image; collapsing one makes it 10,000 pt wide, which pushes
/// every status item to its left off screen.
///
/// - Playing: `outer` collapses (icons hidden, ♪ visible); the toggle has no width.
///   Clicking ♪ opens its window and reveals the icons until it closes.
/// - Not playing, hidden: `inner` collapses, so ♪ hides along with the icons and only
///   ‹ is left. Clicking ‹ reveals everything and turns it into ›.
///
/// Nothing is ever removed from the menu bar (isVisible = false / isInserted = false):
/// macOS forgets a removed item's position, and ♪ came back behind the notch.
///
/// Which icons hide is up to the user: ⌘-drag them left of ♪, or right of the
/// toggle to keep them. Icons of apps launched later land on the left.
@MainActor
final class MenuBarDividerController: NSObject {
    private let model: LyricsModel
    private var outer: NSStatusItem?
    private var inner: NSStatusItem?
    private var toggle: NSStatusItem?
    /// Set once ♪ has been seen right of `outer` (see `canCollapseOuter`).
    private var orderVerified = false

    static let collapsedLength: CGFloat = 10_000
    private static let outerName = "LyricsOverlayDivider"
    private static let innerName = "LyricsOverlayInnerDivider"
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
    /// around ♪: outer just left, inner and toggle just right. Measured only while ♪
    /// is on screen, and stored values are never overwritten; after that macOS
    /// remembers wherever the user ⌘-drags them.
    private func createItems() {
        let d = UserDefaults.standard
        if let window = lyricsItemWindow, let screen = window.screen,
           window.frame.minX > screen.frame.minX + 100,
           let lyricsName = Self.statusItem(of: window)?.autosaveName {
            let lyricsKey = Self.positionKey(lyricsName)
            let lyricsPosition = d.object(forKey: lyricsKey) as? Double
                ?? Double(screen.frame.maxX - window.frame.maxX)
            for (key, value) in [(lyricsKey, lyricsPosition),
                                 (Self.positionKey(Self.outerName), lyricsPosition + 1),
                                 (Self.positionKey(Self.innerName), lyricsPosition - 0.5),
                                 (Self.positionKey(Self.toggleName), lyricsPosition - 1)]
            where d.object(forKey: key) == nil {
                d.set(value, forKey: key)
            }
            model.menuBarPlacementDone = true
        }

        outer = Self.makeExpander(Self.outerName)
        inner = Self.makeExpander(Self.innerName)

        let toggle = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        toggle.autosaveName = Self.toggleName
        toggle.button?.target = self
        toggle.button?.action = #selector(toggleClicked)
        self.toggle = toggle
    }

    private static func makeExpander(_ name: String) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: 0)
        item.autosaveName = name
        item.button?.isEnabled = false
        return item
    }

    @objc private func toggleClicked() {
        model.iconsHiddenWhenIdle.toggle()
    }

    /// The MenuBarExtra's status item window (MenuBarExtra doesn't expose the item).
    private var lyricsItemWindow: NSWindow? {
        let ours = [outer, inner, toggle].compactMap { $0?.button?.window }
        return NSApp.windows.first { w in
            w.className == "NSStatusBarWindow" && w.isVisible && !ours.contains { $0 === w }
        }
    }

    /// The NSStatusItem behind a status bar window, via AppKit's private accessor.
    private static func statusItem(of window: NSWindow) -> NSStatusItem? {
        guard window.responds(to: NSSelectorFromString("statusItem")) else { return nil }
        return window.value(forKey: "statusItem") as? NSStatusItem
    }

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
    /// was stored, so it can sit left of `outer` until a relaunch; collapsing then
    /// would hide ♪ too. Checked once while ♪ is visible.
    private var canCollapseOuter: Bool {
        if orderVerified { return true }
        guard let outerWindow = outer?.button?.window, let lyrics = lyricsItemWindow else { return false }
        orderVerified = lyrics.frame.minX >= outerWindow.frame.maxX - 1
        if !orderVerified { log.info("♪ is left of the divider; not hiding icons until relaunch") }
        return orderVerified
    }

    private func update() {
        guard let outer, let inner, let toggle else { return }
        let enabled = model.hideIconsWhilePlaying
        let playing = model.isPlaying

        let hideAroundLyrics = enabled && playing && !model.isMenuWindowOpen && canCollapseOuter
        let hideEverything = enabled && !playing && model.iconsHiddenWhenIdle && model.menuBarPlacementDone
        outer.length = hideAroundLyrics ? Self.collapsedLength : 0
        inner.length = hideEverything ? Self.collapsedLength : 0

        // The toggle is only usable when nothing is playing; otherwise it takes no space.
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
