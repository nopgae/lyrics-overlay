import concurrent.futures
import requests
from typing import List, Optional

from .lrc_parser import LyricLine, parse_lrc

LRCLIB_BASE = "https://lrclib.net/api"
NETEASE_HEADERS = {
    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)",
    "Referer": "https://music.163.com/",
}
TIMEOUT = 5

# In-memory cache: (title_lower, artist_lower) → lines or None
_cache: dict = {}

# Metadata tag prefixes NetEase embeds at the top of LRC files
_NETEASE_META = ("作词", "作曲", "编曲", "制作", "出品", "录音", "混音", "母带")


def search_lyrics(
    title: str,
    artist: str = "",
    album: str = "",
    duration: float = 0,
) -> Optional[List[LyricLine]]:
    """
    Fetch time-synced lyrics: LRCLIB (exact + search in parallel) first,
    NetEase Music as fallback. Returns a list of LyricLine or None.
    """
    key = (title.lower(), artist.lower())
    if key in _cache:
        return _cache[key]

    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as ex:
        f_exact = ex.submit(_lrclib_exact, title, artist, album, duration)
        f_search = ex.submit(_lrclib_search, title, artist)
        exact = f_exact.result()
        if exact:
            _cache[key] = exact
            return exact
        search = f_search.result()
        if search:
            _cache[key] = search
            return search

    result = _search_netease(title, artist)
    _cache[key] = result  # cache None too, to avoid re-fetching misses
    return result


def _lrclib_exact(
    title: str, artist: str, album: str, duration: float
) -> Optional[List[LyricLine]]:
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
    return None


def _lrclib_search(title: str, artist: str) -> Optional[List[LyricLine]]:
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
