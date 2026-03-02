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
        self._play_btn: NSButton | None = None

    # ------------------------------------------------------------------ #
    # Build                                                                #
    # ------------------------------------------------------------------ #

    def create(self, screen_w: float, screen_h: float, action_target) -> None:
        """
        action_target: the NSObject whose action methods are called by buttons.
        Expected selectors: openFileAction: playPauseAction: stopAction:
                            toggleOverlayAction: opacityAction:
        """
        style = (NSWindowStyleMaskTitled
                 | NSWindowStyleMaskClosable
                 | NSWindowStyleMaskMiniaturizable)
        self._window = NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
            ((screen_w / 2 - 190, screen_h / 2 - 120), (380, 240)),
            style,
            NSBackingStoreBuffered,
            False,
        )
        self._window.setTitle_("Lyrics Overlay")
        self._window.setReleasedWhenClosed_(False)
        self._window.setDelegate_(action_target)

        cv = self._window.contentView()

        # ── track / status ────────────────────────────────────────────
        self._track_lbl  = self._label(cv, "No track loaded", (10, 210, 360, 18), 12, bold=True)
        self._status_lbl = self._label(cv, "Ready",           (10, 192, 360, 16), 10, alpha=0.6)

        # ── transport buttons ─────────────────────────────────────────
        self._btn(cv, "Open MP3…",      (10,  158, 110, 28), action_target, "openFileAction:")
        self._play_btn = \
            self._btn(cv, "Play",       (130, 158,  60, 28), action_target, "playPauseAction:")
        self._btn(cv, "Stop",           (200, 158,  60, 28), action_target, "stopAction:")
        self._btn(cv, "Toggle Overlay", (270, 158, 100, 28), action_target, "toggleOverlayAction:")

        # ── opacity slider ────────────────────────────────────────────
        self._label(cv, "Overlay opacity:", (10, 128, 120, 18), 10)
        sl = NSSlider.alloc().initWithFrame_(NSMakeRect(135, 124, 235, 26))
        sl.setMinValue_(0.0)
        sl.setMaxValue_(1.0)
        sl.setFloatValue_(0.78)
        sl.setTarget_(action_target)
        sl.setAction_("opacityAction:")
        cv.addSubview_(sl)

        # ── YouTube Music ─────────────────────────────────────────────
        self._label(cv, "YouTube Music:", (10, 98, 120, 18), 10)
        self._yt_lbl = self._label(cv, "Not detected", (135, 98, 235, 18), 10, alpha=0.6)

        # ── lyrics source ─────────────────────────────────────────────
        self._label(cv, "Lyrics source:", (10, 72, 120, 18), 10)
        self._source_lbl = self._label(cv, "—", (135, 72, 235, 18), 10, alpha=0.6)

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
        lbl.setTextColor_(NSColor.colorWithCalibratedWhite_alpha_(0.1, alpha))
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

    def set_play_title(self, title: str) -> None:
        if self._play_btn:
            self._play_btn.setTitle_(title)
