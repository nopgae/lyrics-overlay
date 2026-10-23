import AppKit

/// Bartender-style hiding of other menu bar icons. Two extra status items around the
/// lyrics (♪) item:
///
///     [icons to hide] [expander] [♪] [‹ toggle] [system icons]
///
/// The expander has no image; while hiding it is 10,000 pt wide, which pushes every
/// status item to its left off screen. The toggle is the ‹ / › button.
///
/// - Playing: icons are hidden and the toggle is gone. Clicking ♪ opens the window
///   and reveals the icons until it closes.
/// - Not playing: the toggle shows. ‹ means hidden (♪ is hidden too); clicking it
///   reveals ♪ and the icons and turns into ›, which hides them again.
///
/// Which icons hide is up to the user: ⌘-drag them left of ♪ (or right of the
/// toggle to keep them visible). Icons of apps launched later land on the left.
@MainActor
final class MenuBarDividerController: NSObject {
    private let model: LyricsModel
    private var expander: NSStatusItem?
    private var toggle: NSStatusItem?
    /// Set once the ♪ item has been seen right of the expander (see `canCollapse`).
    private var orderVerified = false

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
    /// position (like the MenuBarExtra's) is put leftmost too. On first run, store
    /// preferred positions — distance from the screen's right edge, larger = further
    /// left — for all three: ♪ where it is now, the expander just left of it and the
    /// toggle just right of it. After that macOS remembers where the user ⌘-drags them.
    private func createItems() {
        // Measure ♪ only when it is really on screen, and never overwrite stored
        // positions (a bad measurement would otherwise stick across launches).
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

        let expander = NSStatusBar.system.statusItem(withLength: 0)
        expander.autosaveName = Self.expanderName
        expander.button?.isEnabled = false
        self.expander = expander

        let toggle = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        toggle.autosaveName = Self.toggleName
        toggle.button?.target = self
        toggle.button?.action = #selector(toggleClicked)
        self.toggle = toggle
    }

    @objc private func toggleClicked() {
        model.iconsHiddenWhenIdle.toggle()
    }

    /// The MenuBarExtra's status item window (MenuBarExtra doesn't expose the item).
    private var lyricsItemWindow: NSWindow? {
        let ours = [expander?.button?.window, toggle?.button?.window].compactMap { $0 }
        return NSApp.windows.first { w in
            w.className == "NSStatusBarWindow" && w.isVisible && !ours.contains { $0 === w }
        }
    }

    /// The NSStatusItem behind a status bar window, via AppKit's private accessor.
    private static func statusItem(of window: NSWindow) -> NSStatusItem? {
        guard window.responds(to: NSSelectorFromString("statusItem")) else { return nil }
        return window.value(forKey: "statusItem") as? NSStatusItem
    }

    var shouldHideIcons: Bool {
        guard model.hideIconsWhilePlaying else { return false }
        return model.isPlaying ? !model.isMenuWindowOpen : model.iconsHiddenWhenIdle
    }

    private func observe() {
        withObservationTracking {
            _ = shouldHideIcons
            _ = model.hideIconsWhilePlaying
            _ = model.isPlaying
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
    /// was stored, so it can sit on the wrong side of the expander until a relaunch;
    /// collapsing then would hide ♪ too. Check once while ♪ is visible.
    private var canCollapse: Bool {
        if orderVerified { return true }
        // ♪ is out of the menu bar while idle-hidden, so it can't be measured; once a
        // placement has been stored, trust it.
        if model.menuBarPlacementDone && !model.isMenuBarItemInserted { return true }
        guard let expanderWindow = expander?.button?.window, let lyrics = lyricsItemWindow else {
            return false
        }
        orderVerified = lyrics.frame.minX >= expanderWindow.frame.maxX - 1
        if !orderVerified { log.info("♪ is left of the expander; not hiding icons until relaunch") }
        return orderVerified
    }

    private func update() {
        guard let expander, let toggle else { return }
        let enabled = model.hideIconsWhilePlaying
        expander.isVisible = enabled
        expander.length = shouldHideIcons && canCollapse ? Self.collapsedLength : 0

        // The toggle is only there when nothing is playing.
        toggle.isVisible = enabled && !model.isPlaying
        let hidden = model.iconsHiddenWhenIdle
        let image = NSImage(systemSymbolName: hidden ? "chevron.compact.left" : "chevron.compact.right",
                            accessibilityDescription: hidden ? "Show menu bar icons" : "Hide menu bar icons")
        image?.isTemplate = true
        toggle.button?.image = image
        toggle.button?.toolTip = hidden ? "Show hidden menu bar icons" : "Hide menu bar icons"
    }
}
