import bisect
from typing import List, Tuple

from .lrc_parser import LyricLine


class SyncEngine:
    def __init__(self) -> None:
        self._lyrics: List[LyricLine] = []
        self._times: List[float] = []   # parallel sorted times for bisect

    def set_lyrics(self, lyrics: List[LyricLine]) -> None:
        self._lyrics = sorted(lyrics, key=lambda x: x.time)
        self._times = [l.time for l in self._lyrics]

    def clear(self) -> None:
        self._lyrics = []
        self._times = []

    @property
    def has_lyrics(self) -> bool:
        return bool(self._lyrics)

    def _index_at(self, position: float) -> int:
        """Return index of the last line whose timestamp <= position, or -1."""
        return bisect.bisect_right(self._times, position) - 1

    def get_context(
        self, position: float, before: int = 1, after: int = 1
    ) -> Tuple[List[str], str, List[str]]:
        """Return (prev_lines, current_text, next_lines) for the given position."""
        if not self._lyrics:
            return [], "", []

        idx = self._index_at(position)

        if idx == -1:
            return [], "", [l.text for l in self._lyrics[:after]]

        current = self._lyrics[idx].text
        prevs = [self._lyrics[i].text for i in range(max(0, idx - before), idx)]
        nexts = [
            self._lyrics[i].text
            for i in range(idx + 1, min(len(self._lyrics), idx + 1 + after))
        ]
        return prevs, current, nexts
