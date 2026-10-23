import AppKit

/// Hides other menu bar icons while lyrics play, Hidden Bar style: an extra status
/// item sits just left of the lyrics item, and while collapsed it is 10,000 pt wide,
/// which pushes every status item to its left off screen. Opening the lyrics window
/// expands it again so those icons are reachable until the window closes.
///
/// Which icons hide is up to the user: ⌘-drag them to the left of the ‹ divider.
/// (Icons of apps launched after this one land on the left automatically.)
@MainActor
final class MenuBarDividerController {
    private let model: LyricsModel
    private var item: NSStatusItem?
    private var collapsed = false

    static let collapsedLength: CGFloat = 10_000
    private static let autosaveName = "LyricsOverlayDivider"
    private static let positionKey = "NSStatusItem Preferred Position \(autosaveName)"
    /// Bumped when the initial placement logic changes, to re-place the divider once.
    private static let placementVersion = 3

    init(model: LyricsModel) {
        self.model = model
        // Wait for the MenuBarExtra item to be laid out so we can measure it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.createItem()
            self?.observe()
        }
    }

    /// New status items appear left of *all* others, and an item with no stored
    /// position (like the MenuBarExtra's) is put leftmost too. On first run, store
    /// preferred positions — distance from the screen's right edge, larger = further
    /// left — for both: the lyrics item where it is now and the divider just left of
    /// it. After that macOS remembers wherever the user ⌘-drags them.
    private func createItem() {
        let d = UserDefaults.standard
        if d.integer(forKey: "dividerPlacementVersion") < Self.placementVersion,
           let window = Self.lyricsItemWindow, let screen = window.screen,
           let lyricsName = Self.statusItem(of: window)?.autosaveName {
            let lyricsPosition = Double(screen.frame.maxX - window.frame.maxX)
            d.set(lyricsPosition, forKey: "NSStatusItem Preferred Position \(lyricsName)")
            d.set(lyricsPosition + 1, forKey: Self.positionKey)
            d.set(Self.placementVersion, forKey: "dividerPlacementVersion")
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = Self.autosaveName
        if let button = item.button {
            let image = NSImage(systemSymbolName: "chevron.compact.left",
                                accessibilityDescription: "Lyrics Overlay divider")
            image?.isTemplate = true
            button.image = image
            button.appearsDisabled = true
            button.toolTip = "Lyrics Overlay: ⌘-drag icons to the left of this mark to hide them while lyrics play"
        }
        self.item = item
    }

    /// The MenuBarExtra's status item window (MenuBarExtra doesn't expose the item).
    /// Before the divider exists this is the only status bar window we own.
    private static var lyricsItemWindow: NSWindow? {
        NSApp.windows.first { $0.className == "NSStatusBarWindow" && $0.isVisible }
    }

    /// The NSStatusItem behind a status bar window, via AppKit's private accessor.
    private static func statusItem(of window: NSWindow) -> NSStatusItem? {
        guard window.responds(to: NSSelectorFromString("statusItem")) else { return nil }
        return window.value(forKey: "statusItem") as? NSStatusItem
    }

    var shouldCollapse: Bool {
        model.hideIconsWhilePlaying && model.isPlaying && model.menuBarTitle != nil && !model.isMenuWindowOpen
    }

    private func observe() {
        withObservationTracking {
            _ = shouldCollapse
            _ = model.hideIconsWhilePlaying
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.update()
                self?.observe()
            }
        }
        update()
    }

    /// True when the lyrics item sits right of the divider. Only measurable while
    /// expanded; on the very first launch the MenuBarExtra item was created before its
    /// position was stored, so it can still be on the wrong side until a relaunch —
    /// collapsing then would hide the lyrics too.
    private var lyricsIsRightOfDivider: Bool {
        guard let dividerWindow = item?.button?.window,
              let lyrics = NSApp.windows.first(where: {
                  $0.className == "NSStatusBarWindow" && $0.isVisible && $0 !== dividerWindow
              }) else { return false }
        return lyrics.frame.minX >= dividerWindow.frame.maxX - 1
    }

    private func update() {
        guard let item else { return }
        item.isVisible = model.hideIconsWhilePlaying
        var collapse = shouldCollapse
        if collapse, !collapsed, !lyricsIsRightOfDivider {
            log.info("Lyrics item is left of the divider; not hiding icons until relaunch")
            collapse = false
        }
        guard collapse != collapsed else { return }
        collapsed = collapse
        item.length = collapse ? Self.collapsedLength : NSStatusItem.variableLength
        item.button?.image?.size = collapse ? .zero : NSSize(width: 9, height: 16)
    }
}
