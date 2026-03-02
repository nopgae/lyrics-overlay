"""
Main application entry point.

Architecture
────────────
AppDelegate (NSObject)
  ├─ LyricsOverlay     – floating NSPanel
  ├─ ControlPanel      – transport / settings window
  ├─ MusicPlayer       – pygame MP3 backend
  └─ SyncEngine        – maps position → lyric line

Two NSTimers run on the main thread:
  • sync_timer  (100 ms)  – updates overlay with current lyric
  • yt_timer    (1.5 s)   – polls YouTube Music in a background thread

A thread-safe queue (_ui_q) carries UI updates from background threads
back to the main-thread timers.
"""

import queue
import sys
import threading
import time
from pathlib import Path

import objc
from AppKit import (
    NSApplication,
    NSApplicationActivationPolicyRegular,
    NSAttributedString,
    NSBezierPath,
    NSColor,
    NSFont,
    NSFontAttributeName,
    NSForegroundColorAttributeName,
    NSImage,
    NSMenu,
    NSMenuItem,
    NSObject,
    NSOpenPanel,
    NSScreen,
    NSStatusBar,
    NSTimer,
    NSVariableStatusItemLength,
)
from Foundation import NSMakePoint, NSMakeRect, NSMakeSize, NSProcessInfo

from .control_panel import ControlPanel
from .lrc_parser import load_lrc_file
from .lyrics_fetcher import search_lyrics
from .overlay import LyricsOverlay
from .player import MusicPlayer
from .sync_engine import SyncEngine
from .music_watcher import get_music_info
from .ytmusic_watcher import get_ytmusic_info


class AppDelegate(NSObject):

    def init(self):
        self = objc.super(AppDelegate, self).init()
        if self is None:
            return None

        self._player = MusicPlayer()
        self._sync = SyncEngine()
        self._overlay = LyricsOverlay()
        self._control = ControlPanel()

        # External source state (Music.app / YouTube Music)
        self._yt_info: dict | None = None
        self._yt_fetch_key: tuple | None = None
        self._yt_last_poll_wall: float = 0.0
        self._yt_last_poll_pos: float = 0.0

        self._music_info: dict | None = None
        self._music_fetch_key: tuple | None = None
        self._music_last_poll_wall: float = 0.0
        self._music_last_poll_pos: float = 0.0

        # Thread-safe queue for UI updates from background threads
        self._ui_q: queue.SimpleQueue = queue.SimpleQueue()

        self._current_track: dict = {}

        return self

    # ------------------------------------------------------------------ #
    # App lifecycle                                                        #
    # ------------------------------------------------------------------ #

    def applicationDidFinishLaunching_(self, _notif):
        screen = NSScreen.mainScreen()
        sw = screen.frame().size.width
        sh = screen.frame().size.height

        self._setup_main_menu()

        self._overlay.create(sw, sh)
        self._control.create(sw, sh, self)  # pass self as action target
        self._set_app_icon()

        self._overlay.update(
            current="♪  Lyrics Overlay",
            next_line="Open an MP3 or play a song in YouTube Music",
        )

        self._setup_status_bar()
        NSApplication.sharedApplication().activateIgnoringOtherApps_(True)

        # 250 ms lyric sync timer (lyrics change ~1/s, 4fps is more than enough)
        self._sync_timer = NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
            0.25, self, "syncTick:", None, True
        )

        # 2 s YouTube Music poll timer
        self._yt_timer = NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
            2.0, self, "ytTick:", None, True
        )

        self._player.on_track_end = self._on_track_end

    def applicationShouldTerminateAfterLastWindowClosed_(self, _app):
        return False

    # ------------------------------------------------------------------ #
    # Timers (main thread)                                                 #
    # ------------------------------------------------------------------ #

    def syncTick_(self, _timer):
        # Drain UI update queue
        while True:
            try:
                fn = self._ui_q.get_nowait()
                fn()
            except queue.Empty:
                break

        # Skip if nothing is actively playing
        if not self._sync.has_lyrics:
            return
        if not (self._player.is_playing or self._player.is_paused
                or self._yt_info or self._music_info):
            return

        pos = self._current_position()
        _, current, nexts = self._sync.get_context(pos, before=0, after=1)
        self._overlay.update(
            current=current,
            next_line=nexts[0] if nexts else "",
        )

    def ytTick_(self, _timer):
        # No need to poll external sources while the MP3 player is active
        if self._player.is_playing or self._player.is_paused:
            return

        def _poll():
            music = get_music_info()
            yt = None if music else get_ytmusic_info()
            self._ui_q.put(lambda m=music, y=yt: self._apply_sources(m, y))

        threading.Thread(target=_poll, daemon=True).start()

    # ------------------------------------------------------------------ #
    # External sources (Music.app / YouTube Music)                        #
    # ------------------------------------------------------------------ #

    def _apply_sources(self, music_info: dict | None, yt_info: dict | None):
        """Route results from the background poll to the right handler."""
        if music_info:
            self._yt_info = None
            self._yt_fetch_key = None
            self._apply_music_info(music_info)
        else:
            self._music_info = None
            self._music_fetch_key = None
            self._apply_yt_info(yt_info)

    def _apply_music_info(self, info: dict):
        """Called on main thread via _ui_q."""
        self._music_info = info
        self._music_last_poll_wall = time.time()
        self._music_last_poll_pos = info["current_time"]

        title = info.get("title", "")
        artist = info.get("artist", "")
        label = f"Music.app: {title}  —  {artist}" if artist else f"Music.app: {title}"
        self._control.update_yt(label)

        key = (title, artist)
        if key != self._music_fetch_key:
            self._music_fetch_key = key
            if self._player.is_playing or self._player.is_paused:
                self._player.stop()
                self._control.set_play_title("Play")
            self._control.update_track(title, artist)
            self._fetch_lyrics(title, artist, duration=info.get("duration", 0))

    def _apply_yt_info(self, info: dict | None):
        """Called on main thread via _ui_q."""
        if not info:
            self._yt_info = None
            self._control.update_yt("Not playing")
            return

        self._yt_info = info
        self._yt_last_poll_wall = time.time()
        self._yt_last_poll_pos = info["current_time"]

        title = info.get("title", "")
        artist = info.get("artist", "")
        label = f"YT Music: {title}  —  {artist}" if artist else f"YT Music: {title}"
        self._control.update_yt(label)

        key = (title, artist)
        if key != self._yt_fetch_key:
            self._yt_fetch_key = key
            if self._player.is_playing or self._player.is_paused:
                self._player.stop()
                self._control.set_play_title("Play")
            self._control.update_track(title, artist)
            self._fetch_lyrics(title, artist, duration=info.get("duration", 0))

    # ------------------------------------------------------------------ #
    # Position                                                             #
    # ------------------------------------------------------------------ #

    def _current_position(self) -> float:
        # MP3 player has priority
        if self._player.is_playing or self._player.is_paused:
            return self._player.position

        # Music.app or YouTube Music: interpolate between polls
        if self._music_info:
            return self._music_last_poll_pos + (time.time() - self._music_last_poll_wall)
        if self._yt_info:
            return self._yt_last_poll_pos + (time.time() - self._yt_last_poll_wall)

        return 0.0

    # ------------------------------------------------------------------ #
    # Control panel ObjC actions (called directly by buttons / slider)    #
    # ------------------------------------------------------------------ #

    def openFileAction_(self, _sender):
        self._open_file()

    def playPauseAction_(self, _sender):
        self._toggle_play()

    def stopAction_(self, _sender):
        self._player.stop()
        self._control.set_play_title("Play")
        self._control.update_status("Stopped")

    def toggleOverlayAction_(self, _sender):
        self._overlay.set_visible(not self._overlay.is_visible())

    def opacityAction_(self, sender):
        self._overlay.set_opacity(sender.floatValue())

    def _open_file(self):
        panel = NSOpenPanel.openPanel()
        panel.setAllowedFileTypes_(["mp3", "m4a", "flac", "wav", "ogg"])
        panel.setCanChooseFiles_(True)
        panel.setCanChooseDirectories_(False)
        panel.setAllowsMultipleSelection_(False)
        if panel.runModal() == 1:  # NSModalResponseOK
            path = panel.URL().path()
            self._load_mp3(path)

    def _load_mp3(self, path: str):
        if not self._player.load(path):
            self._control.update_status("Failed to load file")
            return

        info = self._player.get_track_info()
        self._current_track = info
        title = info.get("title") or Path(path).stem
        artist = info.get("artist", "")
        self._control.update_track(title, artist)
        self._control.update_status("Loaded — press Play")
        self._yt_info = None    # MP3 mode takes over
        self._music_info = None

        # LRC file next to the MP3?
        lrc = Path(path).with_suffix(".lrc")
        if lrc.exists():
            lines = load_lrc_file(str(lrc))
            if lines:
                self._sync.set_lyrics(lines)
                self._control.update_source(f"Local LRC  ({len(lines)} lines)")
                return

        self._fetch_lyrics(title, artist, duration=info.get("duration", 0))

    def _fetch_lyrics(self, title: str, artist: str = "", duration: float = 0):
        self._control.update_source("Searching LRCLIB…")

        def _worker():
            lines = search_lyrics(title, artist, duration=duration)
            if lines:
                def _apply():
                    self._sync.set_lyrics(lines)
                    self._control.update_source(f"LRCLIB  ({len(lines)} lines)")
            else:
                def _apply():
                    self._sync.clear()
                    self._control.update_source("Not found")
            self._ui_q.put(_apply)

        threading.Thread(target=_worker, daemon=True).start()

    def _toggle_play(self):
        if self._player.is_playing:
            self._player.pause()
            self._control.set_play_title("Resume")
            self._control.update_status("Paused")
        elif self._player.is_paused:
            self._player.resume()
            self._control.set_play_title("Pause")
            self._control.update_status("Playing")
        elif self._player.is_loaded:
            self._player.play()
            self._control.set_play_title("Pause")
            title = self._current_track.get("title", "Unknown")
            self._control.update_status(f"Playing: {title}")

    def _on_track_end(self):
        def _ui():
            self._control.set_play_title("Play")
            self._control.update_status("Finished")
        self._ui_q.put(_ui)

    # ------------------------------------------------------------------ #
    # Status bar                                                           #
    # ------------------------------------------------------------------ #

    def _set_app_icon(self) -> None:
        """Draw a ♪ icon with proper macOS-style padding."""
        size = 512.0
        pad  = size * 0.10          # ~10% margin — matches other Dock icons
        inner = size - pad * 2
        r    = inner * 0.22         # rounded corner radius

        img = NSImage.alloc().initWithSize_(NSMakeSize(size, size))
        img.lockFocus()

        # Dark navy rounded-rect with padding
        NSColor.colorWithCalibratedRed_green_blue_alpha_(0.08, 0.08, 0.18, 1.0).setFill()
        NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius_(
            NSMakeRect(pad, pad, inner, inner), r, r
        ).fill()

        # White ♪ centred inside the rect
        attrs = {
            NSFontAttributeName: NSFont.systemFontOfSize_(260),
            NSForegroundColorAttributeName: NSColor.whiteColor(),
        }
        note = NSAttributedString.alloc().initWithString_attributes_("♪", attrs)
        note_sz = note.size()
        note.drawAtPoint_(NSMakePoint(
            (size - note_sz.width)  / 2 + 8,
            (size - note_sz.height) / 2,
        ))

        img.unlockFocus()
        NSApplication.sharedApplication().setApplicationIconImage_(img)

    def _setup_main_menu(self):
        """Build the macOS top-left application menu bar."""
        app = NSApplication.sharedApplication()
        menubar = NSMenu.alloc().initWithTitle_("MainMenu")

        # ── Lyrics Overlay app menu ──────────────────────────────────────
        app_item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
            "Lyrics Overlay", None, ""
        )
        menubar.addItem_(app_item)

        app_menu = NSMenu.alloc().initWithTitle_("Lyrics Overlay")

        controls = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
            "Show Controls", "showControls:", ","
        )
        controls.setTarget_(self)
        app_menu.addItem_(controls)

        toggle = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
            "Toggle Overlay", "toggleOverlayMenu:", "/"
        )
        toggle.setTarget_(self)
        app_menu.addItem_(toggle)

        app_menu.addItem_(NSMenuItem.separatorItem())

        hide = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
            "Hide Lyrics Overlay", "hide:", "h"
        )
        hide.setTarget_(app)
        app_menu.addItem_(hide)

        app_menu.addItem_(NSMenuItem.separatorItem())

        quit_item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
            "Quit Lyrics Overlay", "terminate:", "q"
        )
        quit_item.setTarget_(app)
        app_menu.addItem_(quit_item)

        app_item.setSubmenu_(app_menu)
        app.setMainMenu_(menubar)

    def _setup_status_bar(self):
        sb = NSStatusBar.systemStatusBar()
        self._status_item = sb.statusItemWithLength_(NSVariableStatusItemLength)
        self._status_item.button().setTitle_("♪")

        menu = NSMenu.alloc().init()

        show = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
            "Show Controls", "showControls:", ""
        )
        show.setTarget_(self)
        menu.addItem_(show)

        toggle = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
            "Toggle Overlay", "toggleOverlayMenu:", ""
        )
        toggle.setTarget_(self)
        menu.addItem_(toggle)

        menu.addItem_(NSMenuItem.separatorItem())

        quit_item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
            "Quit Lyrics Overlay", "terminate:", "q"
        )
        quit_item.setTarget_(NSApplication.sharedApplication())
        menu.addItem_(quit_item)

        self._status_item.setMenu_(menu)

    def showControls_(self, _):
        if self._control._window:
            NSApplication.sharedApplication().activateIgnoringOtherApps_(True)
            self._control._window.makeKeyAndOrderFront_(None)
            self._overlay.set_movable(True)

    def windowWillClose_(self, notif):
        if notif.object() == self._control._window:
            self._overlay.set_movable(False)

    def toggleOverlayMenu_(self, _):
        self._overlay.set_visible(not self._overlay.is_visible())

    # ------------------------------------------------------------------ #
    # Cleanup                                                              #
    # ------------------------------------------------------------------ #

    def cleanup(self):
        self._player.cleanup()


# ────────────────────────────────────────────────────────────────────────
# Entry point
# ────────────────────────────────────────────────────────────────────────

def main():
    # Set app name in menu bar, Dock, and Activity Monitor
    from Foundation import NSBundle
    _info = NSBundle.mainBundle().infoDictionary()
    _info["CFBundleName"] = "Lyrics Overlay"
    _info["CFBundleDisplayName"] = "Lyrics Overlay"
    NSProcessInfo.processInfo().setProcessName_("Lyrics Overlay")

    app = NSApplication.sharedApplication()
    app.setActivationPolicy_(NSApplicationActivationPolicyRegular)

    delegate = AppDelegate.alloc().init()
    app.setDelegate_(delegate)

    try:
        app.run()
    finally:
        delegate.cleanup()


if __name__ == "__main__":
    main()
