"""macOS Music.app watcher via NSAppleScript (in-process, uses app bundle permissions)."""

import time
from typing import Optional

from .applescript import app_is_running, run_applescript

BUNDLE_ID = "com.apple.Music"

# Returns "" when Music isn't running or is stopped; otherwise a paused track
# is still reported so the app can keep its lyrics instead of re-fetching.
_SCRIPT = """
if application "Music" is not running then return ""
tell application "Music"
    set st to player state
    if st is not playing and st is not paused then return ""
    set t to current track
    return (st as string) & "|||" & (name of t) & "|||" & (artist of t) & "|||" & (album of t) & "|||" & ((player position) as string) & "|||" & ((duration of t) as string)
end tell
return ""
"""


def get_music_info() -> Optional[dict]:
    """Return playback info from Music.app, or None if nothing is loaded."""
    if not app_is_running(BUNDLE_ID):
        return None
    t0 = time.time()
    raw = run_applescript(_SCRIPT)
    fetched_at = (t0 + time.time()) / 2
    if not raw:
        return None
    parts = raw.split("|||")
    if len(parts) < 6:
        return None
    try:
        return {
            "title":        parts[1].strip(),
            "artist":       parts[2].strip(),
            "album":        parts[3].strip(),
            "current_time": float(parts[4].replace(",", ".")),
            "duration":     float(parts[5].replace(",", ".")),
            "paused":       parts[0].strip() == "paused",
            "source":       "music_app",
            "_fetched_at":  fetched_at,
        }
    except Exception:
        return None
