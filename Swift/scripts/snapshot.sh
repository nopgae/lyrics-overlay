#!/bin/bash
# Debug helper: renders the menu bar window to PNGs (needs Screen Recording permission
# for the terminal). Usage: scripts/snapshot.sh OUT_DIR
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:?usage: snapshot.sh OUT_DIR}"
mkdir -p "$OUT"
swift build --package-path "$ROOT" >/dev/null
BIN="$(swift build --package-path "$ROOT" --show-bin-path)/LyricsOverlay"

shot() {  # name, extra env...
    local name="$1"; shift
    local idfile="$OUT/.$name.id"
    rm -f "$idfile"
    env LYRICS_SNAPSHOT="$idfile" "$@" "$BIN" &
    local pid=$!
    for _ in $(seq 50); do [ -s "$idfile" ] && break; sleep 0.1; done
    sleep 0.6   # let SwiftUI finish its first animations
    screencapture -x -o -l "$(cat "$idfile")" "$OUT/$name.png"
    wait "$pid" || true
    rm -f "$idfile"
    echo "$OUT/$name.png"
}

shot demo_dark LYRICS_DEMO=1 LYRICS_DARK=1
shot demo_light LYRICS_DEMO=1 LYRICS_DARK=0
shot empty_dark LYRICS_DARK=1
shot karaoke LYRICS_DEMO=1 LYRICS_TARGET=karaoke
