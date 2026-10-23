import concurrent.futures
import re
from dataclasses import dataclass
from typing import List, Optional

import requests

from .lrc_parser import LyricLine, parse_lrc

LRCLIB_BASE = "https://lrclib.net/api"
LRCLIB_HEADERS = {
    "User-Agent": "Lyrics Overlay (https://github.com/nopgae/lyrics-overlay)",
}
NETEASE_HEADERS = {
    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)",
    "Referer": "https://music.163.com/",
}
TIMEOUT = 5

# A search hit whose length differs from the playing track by more than this
# is a different recording (remix, live, radio edit) and is rejected.
DURATION_TOLERANCE = 3.0

# Metadata tag prefixes NetEase embeds at the top of LRC files
_NETEASE_META = ("作词", "作曲", "编曲", "制作", "出品", "录音", "混音", "母带")

# Video-title noise YouTube Music adds that lyric databases don't have
_TITLE_NOISE = re.compile(
    r"\s*[\(\[](?:official\s*(?:music\s*)?(?:video|audio|mv|visualizer)|"
    r"lyric(?:s)?(?:\s*video)?|m/?v|audio|visualizer|hd|4k|remaster(?:ed)?(?:\s*\d{4})?)"
    r"[\)\]]",
    re.IGNORECASE,
)
_FEAT = re.compile(r"\s*[\(\[]?\s*(?:feat\.?|ft\.?|featuring)\s+[^\)\]]*[\)\]]?", re.IGNORECASE)


@dataclass
class LyricsResult:
    lines: List[LyricLine]
    source: str     # "LRCLIB" | "NetEase"
    synced: bool    # False → timestamps are estimated from plain text


class _FetchError(Exception):
    """A provider failed for a transient reason (network, timeout, 5xx)."""


# (title_lower, artist_lower) → result; None means every provider answered "not found"
_cache: dict[tuple[str, str], Optional[LyricsResult]] = {}


def forget_lyrics(title: str, artist: str = "") -> None:
    """Drop a cached result so the next search hits the network again."""
    _cache.pop((title.lower(), artist.lower()), None)


def clean_title(title: str) -> str:
    """Strip '(Official Video)', 'feat. X' and similar noise from a track title."""
    t = _TITLE_NOISE.sub("", title)
    t = _FEAT.sub("", t)
    return t.strip(" -–—") or title


def clean_artist(artist: str) -> str:
    return re.sub(r"\s*-\s*Topic$", "", artist).strip()


def search_lyrics(
    title: str,
    artist: str = "",
    album: str = "",
    duration: float = 0,
) -> Optional[LyricsResult]:
    """
    Fetch time-synced lyrics: LRCLIB (exact + search in parallel) first,
    NetEase Music as fallback. Plain (unsynced) lyrics are used only when no
    provider has synced ones. Returns None when nothing was found.
    """
    key = (title.lower(), artist.lower())
    if key in _cache:
        return _cache[key]

    had_error = False
    plain: Optional[List[str]] = None

    queries = [(title, clean_artist(artist))]
    cleaned = (clean_title(title), clean_artist(artist))
    if cleaned != queries[0]:
        queries.append(cleaned)

    for q_title, q_artist in queries:
        try:
            result, q_plain = _search_lrclib(q_title, q_artist, album, duration)
        except _FetchError:
            had_error = True
            result, q_plain = None, None
        if result:
            _cache[key] = result
            return result
        plain = plain or q_plain

    for q_title, q_artist in queries:
        try:
            result = _search_netease(q_title, q_artist, duration)
        except _FetchError:
            had_error = True
            result = None
        if result:
            _cache[key] = result
            return result

    if plain:
        result = LyricsResult(_estimate_timing(plain, duration), "LRCLIB", synced=False)
        _cache[key] = result
        return result

    # Only remember a miss when every provider actually answered; a network
    # blip must not hide lyrics for the rest of the session.
    if not had_error:
        _cache[key] = None
    return None


def _estimate_timing(plain: List[str], duration: float) -> List[LyricLine]:
    """Spread plain lyric lines evenly over the track (best effort, unsynced)."""
    step = duration / (len(plain) + 1) if duration else 3.0
    return [LyricLine(time=(i + 0.5) * step, text=ln) for i, ln in enumerate(plain)]


def _duration_ok(candidate: float, duration: float) -> bool:
    return not duration or not candidate or abs(candidate - duration) <= DURATION_TOLERANCE


def _get(url: str, **kwargs) -> requests.Response:
    try:
        resp = requests.get(url, timeout=TIMEOUT, **kwargs)
    except requests.RequestException as e:
        raise _FetchError(str(e)) from e
    if resp.status_code >= 500 or resp.status_code == 429:
        raise _FetchError(f"HTTP {resp.status_code}")
    return resp


def _search_lrclib(
    title: str, artist: str, album: str, duration: float
) -> tuple[Optional[LyricsResult], Optional[List[str]]]:
    """Return (synced result, plain lines) from LRCLIB's /get and /search."""
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as ex:
        f_exact = ex.submit(_lrclib_exact, title, artist, album, duration)
        f_search = ex.submit(_lrclib_search, title, artist, duration)
        errors = 0
        try:
            synced, plain = f_exact.result()
        except _FetchError:
            errors += 1
            synced, plain = None, None
        if synced:
            return LyricsResult(synced, "LRCLIB", synced=True), plain
        try:
            synced = f_search.result()
        except _FetchError:
            errors += 1
            synced = None
        if synced:
            return LyricsResult(synced, "LRCLIB", synced=True), plain
        if errors == 2:
            raise _FetchError("LRCLIB unreachable")
    return None, plain


def _lrclib_exact(
    title: str, artist: str, album: str, duration: float
) -> tuple[Optional[List[LyricLine]], Optional[List[str]]]:
    params: dict = {"track_name": title}
    if artist:
        params["artist_name"] = artist
    if album:
        params["album_name"] = album
    if duration:
        params["duration"] = int(duration)
    resp = _get(f"{LRCLIB_BASE}/get", params=params, headers=LRCLIB_HEADERS)
    if resp.status_code != 200:
        return None, None
    try:
        data = resp.json()
    except ValueError:
        return None, None
    synced = parse_lrc(data.get("syncedLyrics") or "") or None
    plain_text = data.get("plainLyrics") or ""
    plain = [ln for ln in plain_text.splitlines() if ln.strip()] or None
    return synced, plain


def _lrclib_search(title: str, artist: str, duration: float) -> Optional[List[LyricLine]]:
    params = {"track_name": title}
    if artist:
        params["artist_name"] = artist
    resp = _get(f"{LRCLIB_BASE}/search", params=params, headers=LRCLIB_HEADERS)
    if resp.status_code != 200:
        return None
    try:
        items = resp.json()
    except ValueError:
        return None
    for item in items:
        if not _duration_ok(float(item.get("duration") or 0), duration):
            continue
        lines = parse_lrc(item.get("syncedLyrics") or "")
        if lines:
            return lines
    return None


def _search_netease(title: str, artist: str, duration: float) -> Optional[LyricsResult]:
    """Fallback: fetch timestamped lyrics from NetEase Music."""
    query = f"{title} {artist}".strip()
    try:
        resp = requests.post(
            "https://music.163.com/api/search/get",
            headers=NETEASE_HEADERS,
            data={"s": query, "type": 1, "limit": 5},
            timeout=TIMEOUT,
        )
    except requests.RequestException as e:
        raise _FetchError(str(e)) from e
    try:
        songs = resp.json().get("result", {}).get("songs", [])
    except ValueError:
        return None
    song = next(
        (s for s in songs if _duration_ok((s.get("duration") or 0) / 1000, duration)),
        None,
    )
    if song is None:
        return None

    resp = _get(
        f"https://music.163.com/api/song/lyric?id={song['id']}&lv=1",
        headers=NETEASE_HEADERS,
    )
    try:
        lrc_text = resp.json().get("lrc", {}).get("lyric", "")
    except ValueError:
        return None
    lines = parse_lrc(lrc_text)
    # Strip NetEase credit lines that appear at the top (作词, 作曲, etc.)
    lines = [l for l in lines if not l.text.startswith(_NETEASE_META)]
    return LyricsResult(lines, "NetEase", synced=True) if lines else None
