#!/bin/bash
# Builds build/Lyrics-Overlay-<version>.dmg: the app plus an Applications link to drag it onto.
#   SIGN_IDENTITY="..."  passed to build.sh, and also signs the DMG
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/build.sh" >/dev/null

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
DMG="$ROOT/build/Lyrics-Overlay-$VERSION.dmg"
STAGE="$ROOT/build/dmg"

rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$ROOT/build/Lyrics Overlay.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Lyrics Overlay" -srcfolder "$STAGE" -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"

if [ -n "${SIGN_IDENTITY:-}" ]; then
    codesign --force --sign "$SIGN_IDENTITY" "$DMG"
fi
echo "$DMG"
