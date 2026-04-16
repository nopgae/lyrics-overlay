"""
FullLyricsWindow — scrollable window showing all lyric lines,
with the current line highlighted.
"""

from AppKit import (
    NSApplication,
    NSBackingStoreBuffered,
    NSColor,
    NSFont,
    NSFontAttributeName,
    NSForegroundColorAttributeName,
    NSMakeRect,
    NSMutableAttributedString,
    NSScrollView,
    NSTextView,
    NSWindow,
    NSWindowStyleMaskClosable,
    NSWindowStyleMaskMiniaturizable,
    NSWindowStyleMaskResizable,
    NSWindowStyleMaskTitled,
)


class FullLyricsWindow:
    def __init__(self) -> None:
        self._window: NSWindow | None = None
        self._text_view: NSTextView | None = None
        self._ranges: list[tuple[int, int]] = []  # (location, length) per line
        self._current_idx: int = -1

    def create(self, screen_w: float, screen_h: float) -> None:
        style = (NSWindowStyleMaskTitled
                 | NSWindowStyleMaskClosable
                 | NSWindowStyleMaskMiniaturizable
                 | NSWindowStyleMaskResizable)
        self._window = NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
            ((screen_w / 2 + 200, screen_h / 2 - 250), (340, 500)),
            style,
            NSBackingStoreBuffered,
            False,
        )
        self._window.setTitle_("Full Lyrics")
        self._window.setReleasedWhenClosed_(False)

        scroll = NSScrollView.alloc().initWithFrame_(NSMakeRect(0, 0, 340, 500))
        scroll.setHasVerticalScroller_(True)
        scroll.setAutohidesScrollers_(True)
        scroll.setAutoresizingMask_(2 | 16)

        tv = NSTextView.alloc().initWithFrame_(NSMakeRect(0, 0, 340, 500))
        tv.setEditable_(False)
        tv.setSelectable_(False)
        tv.setRichText_(True)
        tv.setDrawsBackground_(True)
        tv.setBackgroundColor_(NSColor.windowBackgroundColor())
        tv.textContainer().setLineFragmentPadding_(12.0)
        tv.setAutoresizingMask_(2 | 16)
        scroll.setDocumentView_(tv)

        self._window.setContentView_(scroll)
        self._text_view = tv

    # ------------------------------------------------------------------ #
    # Public API                                                           #
    # ------------------------------------------------------------------ #

    def set_lyrics(self, lines: list[str]) -> None:
        """Populate the window with lyric lines. Resets highlighting."""
        if not self._text_view:
            return
        self._ranges = []
        self._current_idx = -1

        if not lines:
            self._text_view.textStorage().setAttributedString_(
                NSMutableAttributedString.alloc().initWithString_attributes_(
                    "No lyrics available.", {
                        NSFontAttributeName: NSFont.systemFontOfSize_(13),
                        NSForegroundColorAttributeName: NSColor.secondaryLabelColor(),
                    }
                )
            )
            return

        font = NSFont.systemFontOfSize_(14)
        normal = NSColor.labelColor()
        full = NSMutableAttributedString.alloc().init()
        offset = 0
        for line in lines:
            text = (line.strip() or "·") + "\n"
            piece = NSMutableAttributedString.alloc().initWithString_attributes_(
                text, {NSFontAttributeName: font, NSForegroundColorAttributeName: normal}
            )
            full.appendAttributedString_(piece)
            char_len = len(text)
            self._ranges.append((offset, char_len))
            offset += char_len

        self._text_view.textStorage().setAttributedString_(full)

    def highlight(self, idx: int) -> None:
        """Highlight line at *idx*, un-highlighting the previous one."""
        if not self._text_view or idx == self._current_idx:
            return
        if not self._ranges:
            return

        storage = self._text_view.textStorage()
        storage.beginEditing()

        # Un-highlight previous
        if 0 <= self._current_idx < len(self._ranges):
            storage.addAttribute_value_range_(
                NSForegroundColorAttributeName,
                NSColor.labelColor(),
                self._ranges[self._current_idx],
            )

        # Highlight new
        if 0 <= idx < len(self._ranges):
            storage.addAttribute_value_range_(
                NSForegroundColorAttributeName,
                NSColor.systemYellowColor(),
                self._ranges[idx],
            )
            self._text_view.scrollRangeToVisible_(self._ranges[idx])

        storage.endEditing()
        self._current_idx = idx

    def show(self) -> None:
        if self._window:
            NSApplication.sharedApplication().activateIgnoringOtherApps_(True)
            self._window.makeKeyAndOrderFront_(None)
