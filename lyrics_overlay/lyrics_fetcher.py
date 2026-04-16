import requests
from typing import List, Optional

from .lrc_parser import LyricLine, parse_lrc

LRCLIB_BASE = "https://lrclib.net/api"
NETEASE_HEADERS = {
    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)",
    "Referer": "https://music.163.com/",
}
TIMEOUT = 10

# Metadata tag prefixes NetEase embeds at the top of LRC files
_NETEASE_META = ("作词", "作曲", "编曲", "制作", "出品", "录音", "混音", "母带")


def search_lyrics(
    title: str,
    artist: str = "",
    album: str = "",
    duration: float = 0,
) -> Optional[List[LyricLine]]:
    """
    Fetch time-synced lyrics: LRCLIB first, NetEase Music as fallback.
    Returns a list of LyricLine or None if not found.
    """
    result = _search_lrclib(title, artist, album, duration)
    if result:
        return result
    return _search_netease(title, artist)


def _search_lrclib(
    title: str, artist: str, album: str, duration: float
) -> Optional[List[LyricLine]]:
    # 1) Exact-match endpoint
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

    # 2) Full-text search
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


def _search_netease(title: str, artist: str = "") -> Optional[List[LyricLine]]:
    """Fallback: fetch timestamped lyrics from NetEase Music."""
    query = f"{title} {artist}".strip()
    try:
        resp = requests.post(
            "https://music.163.com/api/search/get",
            headers=NETEASE_HEADERS,
            data={"s": query, "type": 1, "limit": 5},
            timeout=TIMEOUT,
        )
        songs = resp.json().get("result", {}).get("songs", [])
        if not songs:
            return None

        song_id = songs[0]["id"]
        resp = requests.get(
            f"https://music.163.com/api/song/lyric?id={song_id}&lv=1",
            headers=NETEASE_HEADERS,
            timeout=TIMEOUT,
        )
        lrc_text = resp.json().get("lrc", {}).get("lyric", "")
        if not lrc_text:
            return None

        lines = parse_lrc(lrc_text)
        # Strip NetEase credit lines that appear at the top (作词, 作曲, etc.)
        lines = [l for l in lines if not l.text.startswith(_NETEASE_META)]
        return lines or None
    except Exception:
        return None
