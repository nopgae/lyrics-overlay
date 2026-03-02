"""
LyricsOverlay — always-on-top, semi-transparent NSPanel overlay.

Layout (bottom → top in screen coords):
  ┌─────────────────────────────────────────┐
  │  [CURRENT LINE — bright, large, bold]   │
  │  [next line — dim, small]               │
  └─────────────────────────────────────────┘
"""

import objc
from AppKit import (
    NSBackingStoreBuffered,
    NSBezierPath,
    NSColor,
    NSFont,
    NSFloatingWindowLevel,
    NSMakeRect,
    NSPanel,
    NSTextField,
    NSTextAlignmentCenter,
    NSView,
    NSWindowCollectionBehaviorCanJoinAllSpaces,
    NSWindowCollectionBehaviorFullScreenAuxiliary,
    NSWindowCollectionBehaviorStationary,
    NSWindowStyleMaskBorderless,
)

# NSWindowStyleMaskNonactivatingPanel = 128 (NSNonactivatingPanelMask)
_NONACTIVATING = 1 << 7

WINDOW_W = 720
WINDOW_H = 160
CORNER_R = 14


class _LyricsView(NSView):
    """
    Custom NSView that draws a rounded-rect background and hosts two
    NSTextField labels for current / next lyric lines.
    """

    def initWithFrame_(self, frame):
        self = objc.super(_LyricsView, self).initWithFrame_(frame)
        if self is None:
            return None

        self._bg_alpha: float = 0.78
        b = self.bounds()
        w = b.size.width
        h = b.size.height

        # ── labels ─────────────────────────────────────────────────────
        self._curr_lbl = self._make_field(20, 1.00, bold=True, wrap=True)
        self._next_lbl = self._make_field(13, 0.50, wrap=False)

        self.addSubview_(self._curr_lbl)
        self.addSubview_(self._next_lbl)

        # Centre the curr+next pair vertically:
        # curr=68, gap=8, next=22 → total=98 → margin=(h-98)/2
        pad = 24
        margin = (h - 98) / 2
        self._next_lbl.setFrame_(NSMakeRect(pad, margin,      w - pad * 2, 22))
        self._curr_lbl.setFrame_(NSMakeRect(pad, margin + 30, w - pad * 2, 68))

        return self

    # ------------------------------------------------------------------ #

    @staticmethod
    def _make_field(size: int, alpha: float, bold: bool = False, wrap: bool = False) -> NSTextField:
        lbl = NSTextField.alloc().initWithFrame_(NSMakeRect(0, 0, 10, 10))
        lbl.setBezeled_(False)
        lbl.setDrawsBackground_(False)
        lbl.setEditable_(False)
        lbl.setSelectable_(False)
        lbl.setAlignment_(NSTextAlignmentCenter)
        lbl.setTextColor_(
            NSColor.colorWithCalibratedRed_green_blue_alpha_(1.0, 1.0, 1.0, alpha)
        )
        font = NSFont.boldSystemFontOfSize_(size) if bold else NSFont.systemFontOfSize_(size)
        lbl.setFont_(font)
        if wrap:
            lbl.setMaximumNumberOfLines_(2)
            lbl.cell().setWraps_(True)
            lbl.cell().setScrollable_(False)
        else:
            lbl.cell().setWraps_(False)
            lbl.cell().setScrollable_(True)
        return lbl

    # ------------------------------------------------------------------ #
    # Drawing                                                              #
    # ------------------------------------------------------------------ #

    _movable: bool = True   # toggled by LyricsOverlay.set_movable()

    def isOpaque(self) -> bool:
        return False

    def drawRect_(self, dirty_rect) -> None:
        bg = NSColor.colorWithCalibratedRed_green_blue_alpha_(
            0.04, 0.04, 0.12, self._bg_alpha
        )
        path = NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius_(
            self.bounds(), CORNER_R, CORNER_R
        )
        bg.setFill()
        path.fill()

    # ------------------------------------------------------------------ #
    # Public                                                               #
    # ------------------------------------------------------------------ #

    def set_lyrics(self, current: str = "", next_line: str = "") -> None:
        # Only update labels that actually changed to avoid unnecessary redraws
        if current != self._curr_lbl.stringValue():
            self._curr_lbl.setStringValue_(current)
        if next_line != self._next_lbl.stringValue():
            self._next_lbl.setStringValue_(next_line)

    def set_bg_alpha(self, alpha: float) -> None:
        self._bg_alpha = max(0.0, min(1.0, alpha))
        self.setNeedsDisplay_(True)

    def mouseDownCanMoveWindow(self) -> bool:
        return self._movable


class LyricsOverlay:
    """Manages the floating lyrics NSPanel window."""

    def __init__(self) -> None:
        self._window: NSPanel | None = None
        self._view: _LyricsView | None = None

    def create(self, screen_w: float, screen_h: float) -> None:
        x = (screen_w - WINDOW_W) / 2
        y = screen_h * 0.12

        style = NSWindowStyleMaskBorderless | _NONACTIVATING
        panel = NSPanel.alloc().initWithContentRect_styleMask_backing_defer_(
            ((x, y), (WINDOW_W, WINDOW_H)),
            style,
            NSBackingStoreBuffered,
            False,
        )

        panel.setLevel_(NSFloatingWindowLevel)
        panel.setOpaque_(False)
        panel.setBackgroundColor_(NSColor.clearColor())
        panel.setHasShadow_(True)
        panel.setMovableByWindowBackground_(True)
        panel.setReleasedWhenClosed_(False)
        panel.setCollectionBehavior_(
            NSWindowCollectionBehaviorCanJoinAllSpaces
            | NSWindowCollectionBehaviorStationary
            | NSWindowCollectionBehaviorFullScreenAuxiliary
        )

        view = _LyricsView.alloc().initWithFrame_(((0, 0), (WINDOW_W, WINDOW_H)))
        panel.setContentView_(view)

        self._window = panel
        self._view = view

        panel.orderFront_(None)

    def update(self, current: str = "", next_line: str = "") -> None:
        if self._view:
            self._view.set_lyrics(current, next_line)

    def set_visible(self, visible: bool) -> None:
        if not self._window:
            return
        if visible:
            self._window.orderFront_(None)
        else:
            self._window.orderOut_(None)

    def is_visible(self) -> bool:
        return self._window is not None and self._window.isVisible()

    def set_opacity(self, alpha: float) -> None:
        if self._view:
            self._view.set_bg_alpha(alpha)

    def set_movable(self, movable: bool) -> None:
        if self._view:
            self._view._movable = movable
        if self._window:
            self._window.setMovableByWindowBackground_(movable)

    def set_delegate(self, delegate) -> None:
        if self._window:
            self._window.setDelegate_(delegate)

    def set_position(self, x: float, y: float) -> None:
        if self._window:
            self._window.setFrameOrigin_((x, y))

    def get_origin(self):
        if self._window:
            return self._window.frame().origin
        return None
