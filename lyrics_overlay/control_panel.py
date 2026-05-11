"""
Control panel window — file picker, transport controls, status labels.

Buttons and slider use the AppDelegate (passed as `action_target`) directly
as their ObjC target, eliminating intermediate delegate objects.
"""

from AppKit import (
    NSApplication,
    NSBackingStoreBuffered,
    NSBezelStyleRounded,
    NSButton,
    NSColor,
    NSFont,
    NSMakeRect,
    NSPopUpButton,
    NSSlider,
    NSTextField,
    NSTextAlignmentLeft,
    NSWindow,
    NSWindowStyleMaskClosable,
    NSWindowStyleMaskMiniaturizable,
    NSWindowStyleMaskTitled,
)


class ControlPanel:
    def __init__(self) -> None:
        self._window: NSWindow | None = None
        self._track_lbl: NSTextField | None = None
        self._status_lbl: NSTextField | None = None
        self._yt_lbl: NSTextField | None = None
        self._source_lbl: NSTextField | None = None
        self._mode_btn: NSButton | None = None
        self._opacity_slider: NSSlider | None = None
        self._source_popup: NSPopUpButton | None = None

    # ------------------------------------------------------------------ #
    # Build                                                                #
    # ------------------------------------------------------------------ #

    def create(self, screen_w: float, screen_h: float, action_target) -> None:
        """
        action_target: the NSObject whose action methods are called by buttons.
        Expected selectors: toggleLyricsMode: showFullLyricsAction: opacityAction: sourceAction:
        """
        style = (NSWindowStyleMaskTitled
                 | NSWindowStyleMaskClosable
                 | NSWindowStyleMaskMiniaturizable)
        self._window = NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
            ((screen_w / 2 - 190, screen_h / 2 - 135), (380, 270)),
            style,
            NSBackingStoreBuffered,
            False,
        )
        self._window.setTitle_("Lyrics Overlay")
        self._window.setReleasedWhenClosed_(False)
        self._window.setDelegate_(action_target)

        cv = self._window.contentView()

        # ── track / status ────────────────────────────────────────────
        self._track_lbl  = self._label(cv, "No track loaded", (10, 240, 360, 18), 12, bold=True)
        self._status_lbl = self._label(cv, "Ready",           (10, 222, 360, 16), 10, alpha=0.6)

        # ── mode toggle + full lyrics ─────────────────────────────────
        self._mode_btn = self._btn(
            cv, "Mode: Overlay", (10, 188, 180, 28), action_target, "toggleLyricsMode:"
        )
        self._btn(cv, "Full Lyrics", (200, 188, 170, 28), action_target, "showFullLyricsAction:")

        # ── opacity slider ────────────────────────────────────────────
        self._label(cv, "Overlay opacity:", (10, 158, 120, 18), 10)
        sl = NSSlider.alloc().initWithFrame_(NSMakeRect(135, 154, 235, 26))
        sl.setMinValue_(0.0)
        sl.setMaxValue_(1.0)
        sl.setFloatValue_(0.78)
        sl.setTarget_(action_target)
        sl.setAction_("opacityAction:")
        cv.addSubview_(sl)
        self._opacity_slider = sl

        # ── now playing ───────────────────────────────────────────────
        self._label(cv, "Now Playing:", (10, 128, 120, 18), 10)
        self._yt_lbl = self._label(cv, "Not detected", (135, 128, 235, 18), 10, alpha=0.6)

        # ── lyrics source ─────────────────────────────────────────────
        self._label(cv, "Lyrics source:", (10, 102, 120, 18), 10)
        self._source_lbl = self._label(cv, "—", (135, 102, 235, 18), 10, alpha=0.6)

        # ── music player selector ─────────────────────────────────────
        self._label(cv, "Music player:", (10, 74, 120, 18), 10)
        popup = NSPopUpButton.alloc().initWithFrame_(NSMakeRect(135, 70, 235, 26))
        popup.addItemWithTitle_("Auto-detect")
        popup.addItemWithTitle_("YouTube Music")
        popup.addItemWithTitle_("Music.app")
        popup.setTarget_(action_target)
        popup.setAction_("sourceAction:")
        cv.addSubview_(popup)
        self._source_popup = popup

        # ── hint ──────────────────────────────────────────────────────
        self._label(
            cv,
            "Tip: place a .lrc file next to the MP3 for offline lyrics.",
            (10, 16, 360, 32),
            9,
            alpha=0.45,
        )

        NSApplication.sharedApplication().activateIgnoringOtherApps_(True)
        self._window.makeKeyAndOrderFront_(None)

    # ------------------------------------------------------------------ #
    # Helpers                                                              #
    # ------------------------------------------------------------------ #

    def _label(self, parent, text, frame, size, bold=False, alpha=1.0) -> NSTextField:
        lbl = NSTextField.alloc().initWithFrame_(NSMakeRect(*frame))
        lbl.setStringValue_(text)
        lbl.setBezeled_(False)
        lbl.setDrawsBackground_(False)
        lbl.setEditable_(False)
        lbl.setSelectable_(False)
        lbl.setAlignment_(NSTextAlignmentLeft)
        font = NSFont.boldSystemFontOfSize_(size) if bold else NSFont.systemFontOfSize_(size)
        lbl.setFont_(font)
        if alpha >= 1.0:
            lbl.setTextColor_(NSColor.labelColor())
        else:
            lbl.setTextColor_(NSColor.labelColor().colorWithAlphaComponent_(alpha))
        parent.addSubview_(lbl)
        return lbl

    @staticmethod
    def _btn(parent, title, frame, target, action) -> NSButton:
        btn = NSButton.alloc().initWithFrame_(NSMakeRect(*frame))
        btn.setTitle_(title)
        btn.setBezelStyle_(NSBezelStyleRounded)
        btn.setTarget_(target)
        btn.setAction_(action)
        parent.addSubview_(btn)
        return btn

    # ------------------------------------------------------------------ #
    # Update API (main thread only)                                        #
    # ------------------------------------------------------------------ #

    def update_track(self, title: str, artist: str = "") -> None:
        if self._track_lbl:
            self._track_lbl.setStringValue_(f"{title}  —  {artist}" if artist else title)

    def update_status(self, text: str) -> None:
        if self._status_lbl:
            self._status_lbl.setStringValue_(text)

    def update_yt(self, text: str) -> None:
        if self._yt_lbl:
            self._yt_lbl.setStringValue_(text)

    def update_source(self, text: str) -> None:
        if self._source_lbl:
            self._source_lbl.setStringValue_(text)

    def set_mode_label(self, text: str) -> None:
        if self._mode_btn:
            self._mode_btn.setTitle_(text)

    def set_opacity_slider(self, value: float) -> None:
        if self._opacity_slider:
            self._opacity_slider.setFloatValue_(value)

    def set_source_selector(self, index: int) -> None:
        if self._source_popup:
            self._source_popup.selectItemAtIndex_(index)
