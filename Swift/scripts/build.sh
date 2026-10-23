#!/bin/bash
# Builds build/Lyrics Overlay.app.
#   CONFIG=debug|release (default release)
#   SIGN_IDENTITY="..."  stable signing identity; without one the app is ad-hoc signed and
#                        macOS asks for Automation (Apple Events) permission again after every rebuild.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIG:-release}"
APP="$ROOT/build/Lyrics Overlay.app"

swift build --package-path "$ROOT" -c "$CONFIG"
BIN_DIR="$(swift build --package-path "$ROOT" -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/LyricsOverlay" "$APP/Contents/MacOS/LyricsOverlay"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

codesign --force --options runtime \
    --entitlements "$ROOT/Resources/LyricsOverlay.entitlements" \
    --sign "${SIGN_IDENTITY:--}" "$APP"
echo "$APP"
