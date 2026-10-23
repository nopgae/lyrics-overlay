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
  • sync_timer  (250 ms)  – updates overlay with current lyric
  • yt_timer    (1 s)     – polls music sources in a background thread

Music.app and Spotify also post distributed notifications on every play,
pause and track change; those trigger an immediate poll, so while one of
them is the active source the timer only re-polls every few seconds to
catch seeks. YouTube Music (browser) has no notifications and is polled.

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
    NSApplicationDidChangeScreenParametersNotification,
    NSAttributedString,
    NSBackingStoreBuffered,
    NSBezierPath,
    NSButton,
    NSColor,
    NSFont,
    NSFontAttributeName,
    NSForegroundColorAttributeName,
    NSImage,
    NSControlStateValueOff,
    NSControlStateValueOn,
    NSMenu,
    NSMenuItem,
    NSNotificationCenter,
    NSObject,
    NSOpenPanel,
    NSPanel,
    NSScreen,
    NSStatusBar,
    NSTextField,
    NSTextAlignmentCenter,
    NSTimer,
    NSVariableStatusItemLength,
    NSWindowCollectionBehaviorCanJoinAllSpaces,
    NSWindowCollectionBehaviorStationary,
    NSWindowStyleMaskBorderless,
)

from Foundation import (
    NSDistributedNotificationCenter,
    NSMakePoint,
    NSMakeRect,
    NSMakeSize,
    NSProcessInfo,
    NSUserDefaults,
)

from .control_panel import ControlPanel
from .full_lyrics_window import FullLyricsWindow
from .lrc_parser import load_lrc_file
from .lyrics_fetcher import LyricsResult, forget_lyrics, search_lyrics
from .overlay import LyricsOverlay
from .player import MusicPlayer
from .sync_engine import SyncEngine
from .music_watcher import get_music_info
from .spotify_watcher import get_spotify_info
from .ytmusic_watcher import get_ytmusic_info

# Order matches the control panel's "Music player" popup (stored pref values).
_SOURCES = ["auto", "youtube_music", "music_app", "spotify"]
_SOURCE_TITLES = ["Auto-detect", "YouTube Music", "Music.app", "Spotify"]

_PLAYER_NOTIFICATIONS = (
    "com.apple.Music.playerInfo",
    "com.spotify.client.PlaybackStateChanged",
)



class AppDelegate(NSObject):

    def init(self):
        self = objc.super(AppDelegate, self).init()
        if self is None:
            return None

        self._player = MusicPlayer()
        self._sync = SyncEngine()
        self._overlay = LyricsOverlay()
        self._control = ControlPanel()
        self._full_lyrics = FullLyricsWindow()

        # Menu-bar lyrics mode
        self._lyrics_mode: bool = False
        self._lyric_parts: list = []
        self._lyric_part_idx: int = 0
        self._lyric_scroll_tick: int = 0
        self._lyric_last_text: str = ""

        # External source state (Music.app, Spotify or YouTube Music — whichever is active)
        self._ext_info: dict | None = None
        self._ext_fetch_key: tuple | None = None
        self._ext_last_poll_wall: float = 0.0
        self._ext_last_poll_pos: float = 0.0
        self._ext_miss_count: int = 0    # consecutive polls returning nothing
        self._polling: bool = False      # a poll thread is running
        self._poll_again: bool = False   # a poll was requested while one was running
        self._poll_lock = threading.Lock()

        # Bumped on every track change; lyrics fetched for an older
        # generation are discarded instead of overwriting the new track.
        self._fetch_gen: int = 0

        # Music source override: one of _SOURCES
        self._source_override: str = "auto"

        # Seconds the lyrics are held back relative to the reported position
        self._lyric_offset: float = self._DEFAULT_LYRIC_OFFSET

        self._lyrics_status: str = "—"           # e.g. "LRCLIB  (51 lines)"
        self._last_fetch_args: tuple | None = None
        self._status_menu: NSMenu | None = None

        # Thread-safe queue for UI updates from background threads
        self._ui_q: queue.SimpleQueue = queue.SimpleQueue()

        self._current_track: dict = {}
        self._status_item = None  # set by main() before delegate is used

        # Notch-zone fallback panel (used when NSStatusBar slot is in overflow)
        self._notch_panel = None
        self._notch_lbl: NSTextField | None = None

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
        self._full_lyrics.create(sw, sh)
        self._set_app_icon()

        self._overlay.update(
            current="♪  Lyrics Overlay",
            next_line="Play a song in Music, Spotify or YouTube Music",
        )

        self._overlay.set_delegate(self)
        self._setup_status_bar()
        self._load_prefs()
        NSApplication.sharedApplication().activateIgnoringOtherApps_(True)

        # Check for menu bar overflow after 1 s — give SystemUIServer time to place the item
        NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
            1.0, self, "checkNotchFallback:", None, False
        )

        # 250 ms lyric sync timer (lyrics change ~1/s, 4fps is more than enough)
        self._sync_timer = NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
            0.25, self, "syncTick:", None, True
        )

        # 1 s music source poll timer
        self._yt_timer = NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
            1.0, self, "ytTick:", None, True
        )

        self._player.on_track_end = self._on_track_end

        NSNotificationCenter.defaultCenter().addObserver_selector_name_object_(
            self, "screenParametersChanged:",
            NSApplicationDidChangeScreenParametersNotification, None,
        )

        dnc = NSDistributedNotificationCenter.defaultCenter()
        for name in _PLAYER_NOTIFICATIONS:
            dnc.addObserver_selector_name_object_(self, "playerStateChanged:", name, None)

        # Kick off an immediate first poll instead of waiting for the 1s timer
        self._request_poll()

    def applicationShouldTerminateAfterLastWindowClosed_(self, _app):
        return False

    def checkNotchFallback_(self, _timer):
        self._setup_notch_panel_if_needed()

    def screenParametersChanged_(self, _notif):
        """Display connected/disconnected or resolution changed."""
        self._overlay.ensure_on_screen()
        # Rebuild the notch panel for the new geometry (or drop it if the
        # status item is no longer in overflow).
        if self._notch_panel is not None:
            self._notch_panel.orderOut_(None)
            self._notch_panel = None
            self._notch_lbl = None
        NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
            1.0, self, "checkNotchFallback:", None, False
        )

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
        if not (self._player.is_playing or self._player.is_paused or self._ext_info):
            if self._lyrics_mode:
                self._update_status_lyric("")
            return
        if not self._sync.has_lyrics:
            if self._lyrics_mode:
                self._update_status_lyric("")  # falls back to song title
            return

        pos = self._current_position()
        _, current, nexts = self._sync.get_context(pos, before=0, after=1)
        self._overlay.update(
            current=current,
            next_line=nexts[0] if nexts else "",
        )
        self._update_status_lyric(current)
        self._full_lyrics.highlight(self._sync.get_current_idx(pos))

    # Music.app / Spotify notify on changes, so they only need a periodic
    # re-poll to pick up seeks (which post no notification).
    _RESYNC_INTERVAL = 4.0

    def playerStateChanged_(self, _notif):
        """Music.app / Spotify play, pause or track change."""
        self._request_poll()

    def ytTick_(self, _timer):
        info = self._ext_info
        if (info and info["source"] in ("music_app", "spotify")
                and time.time() - self._ext_last_poll_wall < self._RESYNC_INTERVAL):
            return
        self._request_poll()

    def _request_poll(self):
        # No need to poll external sources while the MP3 player is active
        if self._player.is_playing or self._player.is_paused:
            return
        with self._poll_lock:
            if self._polling:
                # Don't start a second thread (stale results could land out of
                # order); have the running one go round once more instead.
                self._poll_again = True
                return
            self._polling = True
        threading.Thread(target=self._poll_worker, daemon=True).start()

    def _poll_worker(self):
        try:
            while True:
                self._poll_again = False
                info = self._poll_sources()
                self._ui_q.put(lambda i=info: self._apply_ext_info(i))
                with self._poll_lock:
                    if not self._poll_again:
                        self._polling = False
                        return
        except Exception:
            with self._poll_lock:
                self._polling = False
            raise

    def _poll_sources(self) -> dict | None:
        """Poll music sources; respects _source_override.

        AppleScript calls are serialized (see applescript.py), so sources are
        queried one after another. In auto mode a playing source beats a
        paused one; on a tie the order is Music.app, Spotify, YouTube Music.
        """
        single = {
            "music_app": get_music_info,
            "spotify": get_spotify_info,
            "youtube_music": get_ytmusic_info,
        }.get(self._source_override)
        if single:
            return single()
        paused = None
        for get_info in (get_music_info, get_spotify_info, get_ytmusic_info):
            info = get_info()
            if info and not info["paused"]:
                return info
            paused = paused or info
        return paused

    # ------------------------------------------------------------------ #
    # External sources (Music.app / Spotify / YouTube Music)              #
    # ------------------------------------------------------------------ #

    _SOURCE_LABELS = {"music_app": "Music.app", "spotify": "Spotify", "youtube_music": "YT Music"}

    def _apply_ext_info(self, info: dict | None):
        """Called on main thread via _ui_q with the result of one poll."""
        if not info:
            self._ext_miss_count += 1
            # Tolerate up to 2 consecutive missed polls (~2 s) before clearing,
            # so brief AppleScript/browser hiccups don't drop lyrics mid-song.
            if self._ext_miss_count >= 3 and self._ext_info is not None:
                self._ext_info = None
                self._control.update_yt("Not playing")
            return

        self._ext_miss_count = 0
        self._ext_info = info
        self._ext_last_poll_wall = info.get("_fetched_at", time.time())
        self._ext_last_poll_pos = info["current_time"]

        title = info.get("title", "")
        artist = info.get("artist", "")
        label = f"{self._SOURCE_LABELS.get(info['source'], '')}: {title}"
        if artist:
            label += f"  —  {artist}"
        if info.get("paused"):
            label += "  (paused)"
        self._control.update_yt(label)

        # Same song from another source (or paused→playing) keeps its lyrics
        key = (title, artist)
        if key != self._ext_fetch_key:
            self._ext_fetch_key = key
            if self._player.is_playing or self._player.is_paused:
                self._player.stop()
            self._sync.clear()
            self._full_lyrics.set_lyrics([])
            self._control.update_track(title, artist)
            self._fetch_lyrics(
                title, artist,
                album=info.get("album", ""),
                duration=info.get("duration", 0),
            )

    # ------------------------------------------------------------------ #
    # Position                                                             #
    # ------------------------------------------------------------------ #

    # Audio hardware buffers ~200ms ahead of perceived output; subtract so
    # lyrics don't appear before you hear the line. Adjustable from the menu
    # (Bluetooth/AirPlay output needs much more).
    _DEFAULT_LYRIC_OFFSET = 0.2

    def _current_position(self) -> float:
        # MP3 player has priority
        if self._player.is_playing or self._player.is_paused:
            return max(0.0, self._player.position - self._lyric_offset)

        # External source: interpolate between polls (not while paused)
        if self._ext_info:
            pos = self._ext_last_poll_pos
            if not self._ext_info.get("paused"):
                pos += time.time() - self._ext_last_poll_wall
            return max(0.0, pos - self._lyric_offset)

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
        self._control.update_status("Stopped")

    def toggleOverlayAction_(self, _sender):
        self._overlay.set_visible(not self._overlay.is_visible())

    def opacityAction_(self, sender):
        alpha = sender.floatValue()
        self._overlay.set_opacity(alpha)
        self._save_pref_float("overlayOpacity", alpha)

    def sourceAction_(self, sender):
        self._set_source_override(_SOURCES[sender.indexOfSelectedItem()])

    def _set_source_override(self, src: str) -> None:
        self._source_override = src
        self._control.set_source_selector(_SOURCES.index(src))
        NSUserDefaults.standardUserDefaults().setObject_forKey_(src, "sourceOverride")
        self._request_poll()

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
        self._ext_info = None   # MP3 mode takes over
        self._ext_fetch_key = None
        self._fetch_gen += 1    # drop any lyrics still in flight for the old track

        # LRC file next to the MP3?
        lrc = Path(path).with_suffix(".lrc")
        if lrc.exists():
            lines = load_lrc_file(str(lrc))
            if lines:
                self._sync.set_lyrics(lines)
                self._full_lyrics.set_lyrics(self._sync.lines)
                self._set_lyrics_status(f"Local LRC  ({len(lines)} lines)")
                return

        self._fetch_lyrics(title, artist, duration=info.get("duration", 0))

    def _set_lyrics_status(self, text: str) -> None:
        self._lyrics_status = text
        self._control.update_source(text)

    def _fetch_lyrics(self, title: str, artist: str = "", album: str = "", duration: float = 0):
        self._last_fetch_args = (title, artist, album, duration)
        self._fetch_gen += 1
        gen = self._fetch_gen
        self._set_lyrics_status("Searching LRCLIB…")

        def _worker():
            result: LyricsResult | None = search_lyrics(
                title, artist, album=album, duration=duration
            )

            def _apply():
                if gen != self._fetch_gen:
                    return  # track changed while we were fetching
                if result:
                    self._sync.set_lyrics(result.lines)
                    self._full_lyrics.set_lyrics(self._sync.lines)
                    sync_note = "" if result.synced else ", unsynced"
                    self._set_lyrics_status(
                        f"{result.source}  ({len(result.lines)} lines{sync_note})"
                    )
                else:
                    self._sync.clear()
                    self._full_lyrics.set_lyrics([])
                    self._set_lyrics_status("Not found")
            self._ui_q.put(_apply)

        threading.Thread(target=_worker, daemon=True).start()

    def _toggle_play(self):
        if self._player.is_playing:
            self._player.pause()
            self._control.update_status("Paused")
        elif self._player.is_paused:
            self._player.resume()
            self._control.update_status("Playing")
        elif self._player.is_loaded:
            self._player.play()
            title = self._current_track.get("title", "Unknown")
            self._control.update_status(f"Playing: {title}")

    def _on_track_end(self):
        def _ui():
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

        for title, action, key in (
            ("Show Lyrics Earlier", "lyricsEarlier:", "["),
            ("Show Lyrics Later", "lyricsLater:", "]"),
        ):
            item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(title, action, key)
            item.setTarget_(self)
            app_menu.addItem_(item)

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
        # _status_item was pre-created in main() to claim the slot early.
        # Just wire up the button target/action here.
        btn = self._status_item.button()
        btn.setTitle_("♪")
        btn.setAccessibilityIdentifier_("io.lyricsoverlay.note")
        self._status_menu = self._build_status_menu()
        self._status_item.setMenu_(self._status_menu)
        self._status_item.setVisible_(True)

    def _is_status_item_overflow(self) -> bool:
        try:
            win = self._status_item.button().window()
            return win is None or win.frame().origin.x < 0
        except Exception:
            return True

    def _setup_notch_panel_if_needed(self) -> None:
        """Create a ♪ panel in the notch zone if the NSStatusBar item is in overflow."""
        if not self._is_status_item_overflow():
            return
        if self._notch_panel is not None:
            return

        screen = NSScreen.mainScreen()
        try:
            left_area = screen.auxiliaryTopLeftArea()
            right_area = screen.auxiliaryTopRightArea()
            notch_x = left_area.origin.x + left_area.size.width
            notch_w = right_area.origin.x - notch_x
            panel_y = right_area.origin.y
            panel_h = right_area.size.height
        except Exception:
            f = screen.frame()
            notch_x = f.size.width * 0.43
            notch_w = f.size.width * 0.14
            panel_y = f.size.height - 32
            panel_h = 32

        _NONACTIVATING = 1 << 7
        style = NSWindowStyleMaskBorderless | _NONACTIVATING
        panel = NSPanel.alloc().initWithContentRect_styleMask_backing_defer_(
            ((notch_x, panel_y), (notch_w, panel_h)),
            style, NSBackingStoreBuffered, False,
        )
        panel.setLevel_(25)  # NSStatusBarWindowLevel — same level as status items
        panel.setOpaque_(False)
        panel.setBackgroundColor_(NSColor.clearColor())
        panel.setHasShadow_(False)
        panel.setIgnoresMouseEvents_(False)
        panel.setCollectionBehavior_(
            NSWindowCollectionBehaviorCanJoinAllSpaces
            | NSWindowCollectionBehaviorStationary
        )

        lbl_h = 18
        lbl_y = (panel_h - lbl_h) / 2
        lbl = NSTextField.alloc().initWithFrame_(
            NSMakeRect(0, lbl_y, notch_w, lbl_h)
        )
        lbl.setBezeled_(False)
        lbl.setDrawsBackground_(False)
        lbl.setEditable_(False)
        lbl.setSelectable_(False)
        lbl.setAlignment_(NSTextAlignmentCenter)
        lbl.setTextColor_(NSColor.whiteColor())
        lbl.setFont_(NSFont.menuBarFontOfSize_(13))
        lbl.cell().setWraps_(False)
        lbl.cell().setScrollable_(True)
        lbl.setStringValue_("♪")
        panel.contentView().addSubview_(lbl)

        # Transparent click-through button covering the whole panel
        click_btn = NSButton.alloc().initWithFrame_(
            NSMakeRect(0, 0, notch_w, panel_h)
        )
        click_btn.setTitle_("")
        click_btn.setBordered_(False)
        click_btn.setTransparent_(True)
        click_btn.setTarget_(self)
        click_btn.setAction_("showStatusMenu:")
        panel.contentView().addSubview_(click_btn)

        self._notch_panel = panel
        self._notch_lbl = lbl
        self._notch_w = notch_w
        panel.orderFrontRegardless()

    _LYRIC_PART_CHARS  = 56   # max chars per part (~400pt with 13pt font)
    _LYRIC_WIDTH       = 400  # status item width in lyrics mode (pts)

    def _set_lyric_text(self, text: str) -> None:
        if self._notch_panel is not None:
            self._notch_lbl.setStringValue_(text or "♪")
        else:
            self._status_item.button().setTitle_(text)
    _LYRIC_PART_TICKS  = 6    # ticks before advancing (6 × 250ms = 1.5 s)

    def _split_lyric(self, text: str) -> list:
        """Split text at word boundaries into ≤_LYRIC_PART_CHARS chunks."""
        if not text:
            return ["♪"]
        if len(text) <= self._LYRIC_PART_CHARS:
            return [text]
        parts, current = [], ""
        for word in text.split():
            candidate = f"{current} {word}".strip()
            if len(candidate) <= self._LYRIC_PART_CHARS:
                current = candidate
            else:
                if current:
                    parts.append(current)
                current = word
        if current:
            parts.append(current)
        return parts or [text[:self._LYRIC_PART_CHARS]]

    def _idle_status_text(self) -> str:
        """Menu-bar text when there is no lyric line: the song, or just ♪."""
        track = self._track_title_artist()
        if not track or not track[0]:
            return "♪"
        title, artist = track
        return f"♪ {title} — {artist}" if artist else f"♪ {title}"

    def _update_status_lyric(self, text: str) -> None:
        if not self._lyrics_mode:
            return
        t = (text or "").strip() or self._idle_status_text()
        if t != self._lyric_last_text:
            self._lyric_last_text = t
            self._lyric_parts = self._split_lyric(t)
            self._lyric_part_idx = 0
            self._lyric_scroll_tick = 0
            self._set_lyric_text(self._lyric_parts[0])
            return
        self._lyric_scroll_tick += 1
        if self._lyric_scroll_tick >= self._LYRIC_PART_TICKS and len(self._lyric_parts) > 1:
            self._lyric_scroll_tick = 0
            self._lyric_part_idx = (self._lyric_part_idx + 1) % len(self._lyric_parts)
            self._set_lyric_text(self._lyric_parts[self._lyric_part_idx])

    def toggleLyricsMode_(self, _sender):
        self._lyrics_mode = not self._lyrics_mode
        if self._lyrics_mode:
            self._status_item.setLength_(self._LYRIC_WIDTH)
            self._overlay.set_visible(False)
            self._set_lyric_text("♪")
            self._control.set_mode_label("Mode: Menu Bar")
        else:
            self._lyric_parts = []
            self._lyric_last_text = ""
            self._status_item.setLength_(NSVariableStatusItemLength)
            self._overlay.set_visible(True)
            self._set_lyric_text("♪")
            self._control.set_mode_label("Mode: Overlay")

    def showFullLyricsAction_(self, _sender):
        self._full_lyrics.show()

    # ------------------------------------------------------------------ #
    # Status item menu                                                     #
    # ------------------------------------------------------------------ #

    def _build_status_menu(self) -> NSMenu:
        menu = NSMenu.alloc().initWithTitle_("Lyrics Overlay")
        menu.setAutoenablesItems_(False)
        menu.setDelegate_(self)  # menuNeedsUpdate_ refreshes titles on open

        def add(title: str, action: str | None = None, key: str = "") -> NSMenuItem:
            item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(title, action, key)
            if action:
                item.setTarget_(self)
            else:
                item.setEnabled_(False)
            menu.addItem_(item)
            return item

        self._mi_now = add("Not playing")
        self._mi_lyrics = add("Lyrics: —")
        menu.addItem_(NSMenuItem.separatorItem())
        self._mi_menubar = add("Show Lyrics in Menu Bar", "toggleLyricsMode:")
        self._mi_overlay = add("Show Overlay", "toggleOverlayMenu:")
        add("Full Lyrics…", "showFullLyricsAction:")
        menu.addItem_(NSMenuItem.separatorItem())
        self._mi_offset = add("Lyric Delay: +0.2 s")
        add("Show Lyrics Earlier", "lyricsEarlier:", "[")
        add("Show Lyrics Later", "lyricsLater:", "]")
        add("Reset Delay", "resetLyricOffset:")
        add("Search Lyrics Again", "refetchLyrics:")
        menu.addItem_(NSMenuItem.separatorItem())

        src_item = add("Music Player", "noop:")
        src_menu = NSMenu.alloc().initWithTitle_("Music Player")
        self._mi_sources = []
        for i, title in enumerate(_SOURCE_TITLES):
            item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
                title, "sourceMenuAction:", ""
            )
            item.setTarget_(self)
            item.setTag_(i)
            src_menu.addItem_(item)
            self._mi_sources.append(item)
        src_item.setSubmenu_(src_menu)

        menu.addItem_(NSMenuItem.separatorItem())
        add("Controls…", "showControls:", ",")
        quit_item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
            "Quit Lyrics Overlay", "terminate:", "q"
        )
        quit_item.setTarget_(NSApplication.sharedApplication())
        menu.addItem_(quit_item)
        return menu

    def menuNeedsUpdate_(self, menu):
        if menu != self._status_menu:
            return
        track = self._track_title_artist()
        if track:
            title, artist = track
            text = f"{title} — {artist}" if artist else title
            paused = (self._ext_info or {}).get("paused") or self._player.is_paused
            self._mi_now.setTitle_(("❚❚ " if paused else "♪ ") + text)
        else:
            self._mi_now.setTitle_("Not playing")
        self._mi_lyrics.setTitle_(f"Lyrics: {self._lyrics_status}")

        def check(item: NSMenuItem, on: bool) -> None:
            item.setState_(NSControlStateValueOn if on else NSControlStateValueOff)

        check(self._mi_menubar, self._lyrics_mode)
        check(self._mi_overlay, self._overlay.is_visible())
        self._mi_offset.setTitle_(f"Lyric Delay: {self._lyric_offset:+.1f} s")
        for i, item in enumerate(self._mi_sources):
            check(item, _SOURCES[i] == self._source_override)

    def showStatusMenu_(self, sender):
        """Notch fallback panel click: pop the same menu under the panel."""
        self.menuNeedsUpdate_(self._status_menu)
        self._status_menu.popUpMenuPositioningItem_atLocation_inView_(
            None, NSMakePoint(0, 0), sender
        )

    def noop_(self, _sender):
        pass

    def sourceMenuAction_(self, sender):
        self._set_source_override(_SOURCES[sender.tag()])

    def lyricsEarlier_(self, _sender):
        self._set_lyric_offset(self._lyric_offset - 0.1)

    def lyricsLater_(self, _sender):
        self._set_lyric_offset(self._lyric_offset + 0.1)

    def resetLyricOffset_(self, _sender):
        self._set_lyric_offset(self._DEFAULT_LYRIC_OFFSET)

    def _set_lyric_offset(self, value: float) -> None:
        self._lyric_offset = round(max(-5.0, min(5.0, value)), 1)
        self._save_pref_float("lyricOffset", self._lyric_offset)

    def refetchLyrics_(self, _sender):
        if not self._last_fetch_args:
            return
        title, artist, album, duration = self._last_fetch_args
        forget_lyrics(title, artist)
        self._sync.clear()
        self._full_lyrics.set_lyrics([])
        self._fetch_lyrics(title, artist, album=album, duration=duration)

    def _track_title_artist(self) -> tuple[str, str] | None:
        if self._ext_info:
            return self._ext_info.get("title", ""), self._ext_info.get("artist", "")
        if self._player.is_loaded and self._current_track:
            return self._current_track.get("title", ""), self._current_track.get("artist", "")
        return None

    def showControls_(self, _):
        if self._control._window:
            NSApplication.sharedApplication().activateIgnoringOtherApps_(True)
            self._control._window.makeKeyAndOrderFront_(None)
            self._overlay.set_movable(True)

    def windowWillClose_(self, notif):
        if notif.object() == self._control._window:
            self._overlay.set_movable(False)

    def windowDidMove_(self, notif):
        if notif.object() == self._overlay._window:
            o = self._overlay.get_origin()
            if o:
                self._save_pref_float("overlayX", o.x)
                self._save_pref_float("overlayY", o.y)

    # ------------------------------------------------------------------ #
    # Preferences (NSUserDefaults)                                         #
    # ------------------------------------------------------------------ #

    @staticmethod
    def _save_pref_float(key: str, value: float) -> None:
        NSUserDefaults.standardUserDefaults().setFloat_forKey_(value, key)

    def _load_prefs(self) -> None:
        prefs = NSUserDefaults.standardUserDefaults()

        if prefs.objectForKey_("overlayOpacity") is not None:
            alpha = prefs.floatForKey_("overlayOpacity")
            self._overlay.set_opacity(alpha)
            self._control.set_opacity_slider(alpha)

        if (prefs.objectForKey_("overlayX") is not None
                and prefs.objectForKey_("overlayY") is not None):
            self._overlay.set_position(
                prefs.floatForKey_("overlayX"),
                prefs.floatForKey_("overlayY"),
            )
            self._overlay.ensure_on_screen()

        src = prefs.stringForKey_("sourceOverride")
        if src in _SOURCES:
            self._source_override = src
            self._control.set_source_selector(_SOURCES.index(src))

        if prefs.objectForKey_("lyricOffset") is not None:
            self._lyric_offset = prefs.floatForKey_("lyricOffset")

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

    # Claim the status bar slot immediately — before app.run() — so the item
    # registers before any competing apps can fill the remaining space.
    _early_status_item = NSStatusBar.systemStatusBar().statusItemWithLength_(
        NSVariableStatusItemLength
    )
    _early_status_item.button().setTitle_("♪")

    delegate = AppDelegate.alloc().init()
    delegate._status_item = _early_status_item
    app.setDelegate_(delegate)

    try:
        app.run()
    finally:
        delegate.cleanup()


if __name__ == "__main__":
    main()
