"""
MenuBarOverlay — NSPanel that visually covers other status-bar icons while
lyrics mode is active, leaving only the ♪ status item visible.
"""

import objc
from AppKit import (
    NSBackingStoreBuffered,
    NSColor,
    NSFont,
    NSPanel,
    NSScreen,
    NSTextField,
    NSTextAlignmentCenter,
    NSVisualEffectView,
    NSWindowCollectionBehaviorCanJoinAllSpaces,
    NSWindowCollectionBehaviorStationary,
    NSWindowStyleMaskBorderless,
)
from Foundation import NSMakeRect

_NONACTIVATING    = 1 << 7   # NSWindowStyleMaskNonactivatingPanel
_MATERIAL_MENUBAR = 12       # NSVisualEffectMaterialMenuBar
_BLENDING_BEHIND  = 0        # NSVisualEffectBlendingModeBehindWindow
_STATE_ACTIVE     = 1        # NSVisualEffectStateActive
_COVER_LEVEL      = 100      # well above NSStatusBarWindowLevel (25)
_MENU_BAR_H       = 28       # standard menu bar height (pts)


class MenuBarOverlay:
    """
    Blurred panel positioned just right of our ♪ status item, covering all
    other status-bar icons. Appears at window level 100 to sit above
    ControlCenter's status item windows.
    """

    def __init__(self, status_item=None) -> None:
        self._status_item = status_item
        self._window: NSPanel | None = None
        self._lbl: NSTextField | None = None
        self._visible: bool = False
        self._create()

    # ------------------------------------------------------------------ #
    # Public API                                                           #
    # ------------------------------------------------------------------ #

    def show(self) -> None:
        if not self._visible:
            self._reposition()
            self._window.orderFrontRegardless()
            self._visible = True

    def hide(self) -> None:
        if self._visible and self._window:
            self._window.orderOut_(None)
            self._visible = False

    def is_visible(self) -> bool:
        return self._visible

    def set_lyric(self, text: str) -> None:
        if self._lbl and text != self._lbl.stringValue():
            self._lbl.setStringValue_(text or "")

    # ------------------------------------------------------------------ #
    # Build                                                                #
    # ------------------------------------------------------------------ #

    def _create(self) -> None:
        screen = NSScreen.mainScreen()
        sw = screen.frame().size.width
        sh = screen.frame().size.height
        x, w = self._calc_xw(sw)
        y = sh - _MENU_BAR_H

        style = NSWindowStyleMaskBorderless | _NONACTIVATING
        panel = NSPanel.alloc().initWithContentRect_styleMask_backing_defer_(
            ((x, y), (w, _MENU_BAR_H)), style, NSBackingStoreBuffered, False
        )
        panel.setLevel_(_COVER_LEVEL)
        panel.setOpaque_(False)
        panel.setBackgroundColor_(NSColor.clearColor())
        panel.setHasShadow_(False)
        panel.setIgnoresMouseEvents_(True)
        panel.setCollectionBehavior_(
            NSWindowCollectionBehaviorCanJoinAllSpaces
            | NSWindowCollectionBehaviorStationary
        )

        vfx = NSVisualEffectView.alloc().initWithFrame_(NSMakeRect(0, 0, w, _MENU_BAR_H))
        vfx.setMaterial_(_MATERIAL_MENUBAR)
        vfx.setBlendingMode_(_BLENDING_BEHIND)
        vfx.setState_(_STATE_ACTIVE)
        vfx.setAutoresizingMask_(2 | 16)

        lbl_h = 18
        lbl_y = (_MENU_BAR_H - lbl_h) / 2
        lbl = NSTextField.alloc().initWithFrame_(NSMakeRect(8, lbl_y, w - 16, lbl_h))
        lbl.setBezeled_(False)
        lbl.setDrawsBackground_(False)
        lbl.setEditable_(False)
        lbl.setSelectable_(False)
        lbl.setAlignment_(NSTextAlignmentCenter)
        lbl.setTextColor_(NSColor.labelColor())
        lbl.setFont_(NSFont.menuBarFontOfSize_(13))
        lbl.cell().setWraps_(False)
        lbl.cell().setScrollable_(True)
        lbl.setAutoresizingMask_(2)
        vfx.addSubview_(lbl)

        panel.setContentView_(vfx)
        self._window = panel
        self._lbl = lbl

    # ------------------------------------------------------------------ #
    # Helpers                                                              #
    # ------------------------------------------------------------------ #

    def _status_item_right_x(self) -> float:
        """Right edge of our ♪ status item in screen coordinates."""
        try:
            if self._status_item is not None:
                btn = self._status_item.button()
                win = btn.window()
                if win is not None:
                    f = btn.frame()
                    return win.frame().origin.x + f.origin.x + f.size.width
        except Exception:
            pass
        return 0.0

    def _calc_xw(self, screen_w: float):
        x = self._status_item_right_x() + 2
        w = max(100.0, screen_w - x)
        return x, w

    def _reposition(self) -> None:
        screen = NSScreen.mainScreen()
        sw = screen.frame().size.width
        sh = screen.frame().size.height
        x, w = self._calc_xw(sw)
        y = sh - _MENU_BAR_H
        if self._window:
            self._window.setFrame_display_(((x, y), (w, _MENU_BAR_H)), False)
