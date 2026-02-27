from typing import List, Optional, Tuple

from .lrc_parser import LyricLine


class SyncEngine:
    def __init__(self) -> None:
        self._lyrics: List[LyricLine] = []

    def set_lyrics(self, lyrics: List[LyricLine]) -> None:
        self._lyrics = sorted(lyrics, key=lambda x: x.time)

    def clear(self) -> None:
        self._lyrics = []

    @property
    def has_lyrics(self) -> bool:
        return bool(self._lyrics)

    def _index_at(self, position: float) -> int:
        """Return index of the last line whose timestamp <= position, or -1."""
        idx = -1
        for i, line in enumerate(self._lyrics):
            if line.time <= position:
                idx = i
            else:
                break
        return idx

    def get_context(
        self, position: float, before: int = 1, after: int = 1
    ) -> Tuple[List[str], str, List[str]]:
        """
        Return (prev_lines, current_text, next_lines) strings for the
        given playback position.
        """
        if not self._lyrics:
            return [], "", []

        idx = self._index_at(position)

        if idx == -1:
            nexts = [l.text for l in self._lyrics[:after]]
            return [], "", nexts

        current = self._lyrics[idx].text
        prevs = [self._lyrics[i].text for i in range(max(0, idx - before), idx)]
        nexts = [
            self._lyrics[i].text
            for i in range(idx + 1, min(len(self._lyrics), idx + 1 + after))
        ]
        return prevs, current, nexts
