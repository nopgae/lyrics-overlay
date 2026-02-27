import re
from dataclasses import dataclass
from typing import List, Optional


@dataclass
class LyricLine:
    time: float  # seconds
    text: str


def parse_lrc(content: str) -> List[LyricLine]:
    """Parse LRC format string into a sorted list of LyricLine objects."""
    lines: List[LyricLine] = []
    # Matches [mm:ss.xx] or [mm:ss:xx]
    time_pattern = re.compile(r"\[(\d+):(\d+(?:[.:]\d+)?)\]")

    for raw in content.splitlines():
        raw = raw.strip()
        if not raw:
            continue

        timestamps: List[float] = []
        last_end = 0
        for m in time_pattern.finditer(raw):
            minutes = int(m.group(1))
            seconds = float(m.group(2).replace(":", "."))
            timestamps.append(minutes * 60 + seconds)
            last_end = m.end()

        if timestamps:
            text = raw[last_end:].strip()
            for ts in timestamps:
                lines.append(LyricLine(time=ts, text=text))

    return sorted(lines, key=lambda x: x.time)


def load_lrc_file(path: str) -> Optional[List[LyricLine]]:
    """Load and parse an LRC file, trying common encodings."""
    for enc in ("utf-8-sig", "utf-8", "cp949", "latin-1"):
        try:
            with open(path, "r", encoding=enc) as f:
                return parse_lrc(f.read())
        except UnicodeDecodeError:
            continue
        except Exception:
            return None
    return None
