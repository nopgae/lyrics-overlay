import threading
import time
from pathlib import Path
from typing import Callable, Optional


class MusicPlayer:
    """
    Thin wrapper around pygame.mixer for MP3 playback.
    Tracks playback position manually for accurate sync.
    """

    def __init__(self) -> None:
        import pygame
        pygame.mixer.init()
        self._pygame = pygame

        self._loaded = False
        self._playing = False
        self._paused = False
        self._file_path: Optional[str] = None

        # Time tracking
        self._seek_offset: float = 0.0   # seconds from start of file
        self._play_wall: float = 0.0     # wall-clock time of last play/resume
        self._paused_at: float = 0.0     # position when paused

        self.on_track_end: Optional[Callable] = None
        self._monitor: Optional[threading.Thread] = None

    # ------------------------------------------------------------------ #
    # Public API                                                           #
    # ------------------------------------------------------------------ #

    def load(self, path: str) -> bool:
        try:
            self._pygame.mixer.music.load(path)
            self._file_path = path
            self._loaded = True
            self._playing = False
            self._paused = False
            self._seek_offset = 0.0
            return True
        except Exception as e:
            print(f"[player] load error: {e}")
            return False

    def play(self, start: float = 0.0) -> None:
        if not self._loaded:
            return
        self._pygame.mixer.music.play(start=start)
        self._seek_offset = start
        self._play_wall = time.time()
        self._playing = True
        self._paused = False
        self._start_monitor()

    def pause(self) -> None:
        if self._playing and not self._paused:
            self._pygame.mixer.music.pause()
            self._paused_at = self.position
            self._paused = True

    def resume(self) -> None:
        if self._paused:
            self._pygame.mixer.music.unpause()
            self._seek_offset = self._paused_at
            self._play_wall = time.time()
            self._paused = False

    def stop(self) -> None:
        self._pygame.mixer.music.stop()
        self._playing = False
        self._paused = False
        self._seek_offset = 0.0

    def seek(self, seconds: float) -> None:
        if not self._loaded:
            return
        self._pygame.mixer.music.play(start=seconds)
        self._seek_offset = seconds
        self._play_wall = time.time()
        self._playing = True
        self._paused = False

    # ------------------------------------------------------------------ #
    # Properties                                                           #
    # ------------------------------------------------------------------ #

    @property
    def position(self) -> float:
        if not self._loaded or not self._playing:
            return 0.0
        if self._paused:
            return self._paused_at
        return self._seek_offset + (time.time() - self._play_wall)

    @property
    def is_playing(self) -> bool:
        return self._playing and not self._paused

    @property
    def is_paused(self) -> bool:
        return self._paused

    @property
    def is_loaded(self) -> bool:
        return self._loaded

    # ------------------------------------------------------------------ #
    # Metadata                                                             #
    # ------------------------------------------------------------------ #

    def get_track_info(self) -> dict:
        if not self._file_path:
            return {}
        p = Path(self._file_path)
        info: dict = {"title": p.stem, "artist": "", "album": "", "duration": 0.0}
        try:
            from mutagen.mp3 import MP3
            audio = MP3(self._file_path)
            info["duration"] = audio.info.length
            tags = audio.tags
            if tags:
                for key, field in [("TIT2", "title"), ("TPE1", "artist"), ("TALB", "album")]:
                    val = tags.get(key)
                    if val:
                        info[field] = str(val).strip()
        except Exception:
            pass
        return info

    def cleanup(self) -> None:
        try:
            self._pygame.mixer.quit()
        except Exception:
            pass

    # ------------------------------------------------------------------ #
    # Internal                                                             #
    # ------------------------------------------------------------------ #

    def _start_monitor(self) -> None:
        if self._monitor and self._monitor.is_alive():
            return

        def _run() -> None:
            while self._playing:
                if not self._pygame.mixer.music.get_busy() and not self._paused:
                    self._playing = False
                    if self.on_track_end:
                        self.on_track_end()
                    break
                time.sleep(0.3)

        self._monitor = threading.Thread(target=_run, daemon=True)
        self._monitor.start()
