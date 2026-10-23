#!/bin/bash
# Rebuilds, relaunches Lyrics Overlay and streams its log.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIG:-debug}" "$ROOT/scripts/build.sh"

pkill -x LyricsOverlay 2>/dev/null || true
open "$ROOT/build/Lyrics Overlay.app"
exec log stream --style compact --predicate 'subsystem == "com.nopgae.lyrics-overlay"'
