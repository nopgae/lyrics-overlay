"""
YouTube Music watcher via NSAppleScript (in-process, uses app bundle permissions).

Supports:
  - Chrome / Brave / Edge / Chromium : execute javascript "..." in tab
  - Safari                            : do JavaScript "..." in tab
"""

import json
import time
from typing import Optional

from .applescript import app_is_running, run_applescript

CHROMIUM_BROWSERS = [
    "Google Chrome",
    "Brave Browser",
    "Microsoft Edge",
    "Chromium",
]

BUNDLE_IDS = {
    "Safari":         "com.apple.Safari",
    "Google Chrome":  "com.google.Chrome",
    "Brave Browser":  "com.brave.Browser",
    "Microsoft Edge": "com.microsoft.edgemac",
    "Chromium":       "org.chromium.Chromium",
}

YT_MUSIC_HOST = "music.youtube.com"

_JS_RAW = """(function(){var v=document.querySelector('video');if(!v)return '';var tEl=document.querySelector('.title.ytmusic-player-bar')||document.querySelector('yt-formatted-string.title');var aEl=document.querySelector('.byline.ytmusic-player-bar a')||document.querySelector('.subtitle a');return JSON.stringify({title:tEl?tEl.textContent.trim():'',artist:aEl?aEl.textContent.trim():'',currentTime:v.currentTime,duration:v.duration||0,paused:v.paused});})()"""
_JS = _JS_RAW.replace('"', '\\"')   # escaped once at import time

# Module-level cache: remember which browser last had YT Music playing
_last_browser: Optional[str] = None


def _parse(raw: str, fetched_at: float) -> Optional[dict]:
    if not raw:
        return None
    try:
        data = json.loads(raw)
        if not data.get("title"):
            return None
        return {
            "title":        data["title"],
            "artist":       data.get("artist", ""),
            "album":        "",
            "current_time": float(data["currentTime"]),
            "duration":     float(data["duration"]),
            "paused":       bool(data.get("paused")),
            "source":       "youtube_music",
            "_fetched_at":  fetched_at,
        }
    except Exception:
        return None


def _query_chromium(app: str) -> Optional[dict]:
    script = f"""
if application "{app}" is not running then return ""
tell application "{app}"
    try
        repeat with w in windows
            repeat with t in tabs of w
                if URL of t contains "{YT_MUSIC_HOST}" then
                    set info to execute javascript "{_JS}" in t
                    if info is not "" then return info
                end if
            end repeat
        end repeat
    end try
end tell
return ""
"""
    t0 = time.time()
    raw = run_applescript(script)
    t1 = time.time()
    return _parse(raw, (t0 + t1) / 2)


def _query_safari() -> Optional[dict]:
    script = f"""
if application "Safari" is not running then return ""
tell application "Safari"
    try
        repeat with w in windows
            repeat with t in tabs of w
                if URL of t contains "{YT_MUSIC_HOST}" then
                    set info to do JavaScript "{_JS}" in t
                    if info is not "" then return info
                end if
            end repeat
        end repeat
    end try
end tell
return ""
"""
    t0 = time.time()
    raw = run_applescript(script)
    t1 = time.time()
    return _parse(raw, (t0 + t1) / 2)


def get_ytmusic_info() -> Optional[dict]:
    """
    Return playback info dict from YouTube Music, or None if no tab has a track.
    Keys: title, artist, album, current_time (seconds), duration (seconds), paused, source
    """
    global _last_browser

    def _query(browser: str) -> Optional[dict]:
        if not app_is_running(BUNDLE_IDS[browser]):
            return None
        return _query_safari() if browser == "Safari" else _query_chromium(browser)

    # Fast path: the browser that was playing last time
    if _last_browser:
        result = _query(_last_browser)
        if result and not result["paused"]:
            return result
        # Paused or gone: scan everything in case another browser is playing

    # Full scan — a playing tab wins over a paused one
    paused_hit: Optional[tuple[str, dict]] = None
    for browser in ["Safari", *CHROMIUM_BROWSERS]:
        result = _query(browser)
        if not result:
            continue
        if not result["paused"]:
            _last_browser = browser
            return result
        if paused_hit is None:
            paused_hit = (browser, result)

    if paused_hit:
        _last_browser = paused_hit[0]
        return paused_hit[1]
    _last_browser = None
    return None
