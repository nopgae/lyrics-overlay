"""
YouTube Music watcher via AppleScript.

Supports:
  - Chrome / Brave / Edge / Chromium : execute javascript "..." in tab
  - Safari                            : do JavaScript "..." in tab

Requirements:
  - Chrome/Brave/Edge: Developer menu → Allow JavaScript from Apple Events
  - Safari: Develop menu → Allow JavaScript from Apple Events
    (Enable Develop menu in Safari → Settings → Advanced)
  - macOS Accessibility permission for the running Python process
"""

import json
import subprocess
from typing import Optional

# (app name, applescript verb to run JS)
CHROMIUM_BROWSERS = [
    "Google Chrome",
    "Brave Browser",
    "Microsoft Edge",
    "Chromium",
]

YT_MUSIC_HOST = "music.youtube.com"

_JS = """(function(){var v=document.querySelector('video');if(!v)return '';var tEl=document.querySelector('.title.ytmusic-player-bar')||document.querySelector('yt-formatted-string.title');var aEl=document.querySelector('.byline.ytmusic-player-bar a')||document.querySelector('.subtitle a');return JSON.stringify({title:tEl?tEl.textContent.trim():'',artist:aEl?aEl.textContent.trim():'',currentTime:v.currentTime,duration:v.duration||0,paused:v.paused});})()"""


def _osascript(script: str) -> str:
    try:
        r = subprocess.run(
            ["osascript", "-e", script],
            capture_output=True, text=True, timeout=5,
        )
        return r.stdout.strip()
    except Exception:
        return ""


def _parse(raw: str) -> Optional[dict]:
    if not raw:
        return None
    try:
        data = json.loads(raw)
        if data.get("paused") or not data.get("title"):
            return None
        return {
            "title":        data["title"],
            "artist":       data.get("artist", ""),
            "current_time": float(data["currentTime"]),
            "duration":     float(data["duration"]),
            "source":       "youtube_music",
        }
    except Exception:
        return None


def _query_chromium(app: str) -> Optional[dict]:
    js = _JS.replace('"', '\\"')
    script = f"""
tell application "System Events"
    if not (exists process "{app}") then return ""
end tell
tell application "{app}"
    try
        repeat with w in windows
            repeat with t in tabs of w
                if URL of t contains "{YT_MUSIC_HOST}" then
                    set info to execute javascript "{js}" in t
                    if info is not "" then return info
                end if
            end repeat
        end repeat
    end try
end tell
return ""
"""
    return _parse(_osascript(script))


def _query_safari() -> Optional[dict]:
    js = _JS.replace('"', '\\"')
    script = f"""
tell application "System Events"
    if not (exists process "Safari") then return ""
end tell
tell application "Safari"
    try
        repeat with w in windows
            repeat with t in tabs of w
                if URL of t contains "{YT_MUSIC_HOST}" then
                    set info to do JavaScript "{js}" in t
                    if info is not "" then return info
                end if
            end repeat
        end repeat
    end try
end tell
return ""
"""
    return _parse(_osascript(script))


def get_ytmusic_info() -> Optional[dict]:
    """
    Return playback info dict from YouTube Music, or None if not playing.

    Keys: title, artist, current_time (seconds), duration (seconds), source
    """
    # Try Safari first if it's likely in use, then Chromium browsers
    result = _query_safari()
    if result:
        return result
    for browser in CHROMIUM_BROWSERS:
        result = _query_chromium(browser)
        if result:
            return result
    return None
