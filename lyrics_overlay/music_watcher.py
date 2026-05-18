"""macOS Music.app watcher via NSAppleScript (in-process, uses app bundle permissions)."""

import time
from typing import Optional

from Foundation import NSAppleScript

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


def _run(source: str) -> str:
    try:
        s = NSAppleScript.alloc().initWithSource_(source)
        desc, err = s.executeAndReturnError_(None)
        if err or desc is None:
            return ""
        v = desc.stringValue()
        return str(v) if v else ""
    except Exception:
        return ""


def get_music_info() -> Optional[dict]:
    """Return playback info from Music.app, or None if not playing."""
    t0 = time.time()
    raw = _run(_SCRIPT)
    fetched_at = (t0 + time.time()) / 2
    if not raw:
        return None
    parts = raw.split("|||")
    if len(parts) < 4:
        return None
    try:
        return {
            "title":        parts[0].strip(),
            "artist":       parts[1].strip(),
            "current_time": float(parts[2]),
            "duration":     float(parts[3]),
            "source":       "music_app",
            "_fetched_at":  fetched_at,
        }
    except Exception:
        return None
