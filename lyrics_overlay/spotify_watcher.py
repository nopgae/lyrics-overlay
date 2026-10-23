"""Spotify watcher via NSAppleScript (in-process, uses app bundle permissions)."""

import time
from typing import Optional

from .applescript import app_is_running, run_applescript

BUNDLE_ID = "com.spotify.client"

# Spotify reports duration in milliseconds and player position in seconds.
_SCRIPT = """
if application id "com.spotify.client" is not running then return ""
tell application id "com.spotify.client"
    set st to player state
    if st is not playing and st is not paused then return ""
    set t to current track
    return (st as string) & "|||" & (name of t) & "|||" & (artist of t) & "|||" & (album of t) & "|||" & ((player position) as string) & "|||" & ((duration of t) as string)
end tell
"""


def get_spotify_info() -> Optional[dict]:
    """Return playback info from Spotify, or None if it isn't running or nothing is loaded."""
    # Checked in Python first: compiling the script needs Spotify's scripting
    # dictionary, and sending it an event would launch the app.
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
            "duration":     float(parts[5].replace(",", ".")) / 1000,
            "paused":       parts[0].strip() == "paused",
            "source":       "spotify",
            "_fetched_at":  fetched_at,
        }
    except Exception:
        return None
