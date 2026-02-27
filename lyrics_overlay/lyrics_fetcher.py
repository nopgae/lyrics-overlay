import requests
from typing import List, Optional

from .lrc_parser import LyricLine, parse_lrc

LRCLIB_BASE = "https://lrclib.net/api"
TIMEOUT = 10


def search_lyrics(
    title: str,
    artist: str = "",
    album: str = "",
    duration: float = 0,
) -> Optional[List[LyricLine]]:
    """
    Fetch time-synced lyrics from LRCLIB.
    Returns a list of LyricLine or None if not found.
    """
    # 1) Try exact-match endpoint
    params: dict = {"track_name": title}
    if artist:
        params["artist_name"] = artist
    if album:
        params["album_name"] = album
    if duration:
        params["duration"] = int(duration)

    try:
        resp = requests.get(f"{LRCLIB_BASE}/get", params=params, timeout=TIMEOUT)
        if resp.status_code == 200:
            data = resp.json()
            synced = data.get("syncedLyrics")
            if synced:
                lines = parse_lrc(synced)
                if lines:
                    return lines
            plain = data.get("plainLyrics")
            if plain:
                return [
                    LyricLine(time=i * 3.0, text=ln)
                    for i, ln in enumerate(plain.splitlines())
                    if ln.strip()
                ]
    except Exception:
        pass

    # 2) Fallback: full-text search
    q = f"{title} {artist}".strip()
    try:
        resp = requests.get(
            f"{LRCLIB_BASE}/search", params={"q": q}, timeout=TIMEOUT
        )
        if resp.status_code == 200:
            for item in resp.json():
                synced = item.get("syncedLyrics")
                if synced:
                    lines = parse_lrc(synced)
                    if lines:
                        return lines
    except Exception:
        pass

    return None
