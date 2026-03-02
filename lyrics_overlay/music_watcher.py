"""macOS Music.app watcher via AppleScript."""

import subprocess
from typing import Optional

_SCRIPT = """
tell application "System Events"
    if not (exists process "Music") then return ""
end tell
tell application "Music"
    if player state is not playing then return ""
    set t to current track
    return (name of t) & "|||" & (artist of t) & "|||" & ((player position) as string) & "|||" & ((duration of t) as string)
end tell
return ""
"""


def get_music_info() -> Optional[dict]:
    """Return playback info from Music.app, or None if not playing."""
    try:
        r = subprocess.run(
            ["osascript", "-e", _SCRIPT],
            capture_output=True, text=True, timeout=5,
        )
        raw = r.stdout.strip()
        if not raw:
            return None
        parts = raw.split("|||")
        if len(parts) < 4:
            return None
        return {
            "title":        parts[0].strip(),
            "artist":       parts[1].strip(),
            "current_time": float(parts[2]),
            "duration":     float(parts[3]),
            "source":       "music_app",
        }
    except Exception:
        return None
