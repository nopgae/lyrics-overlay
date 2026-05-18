#!/bin/bash
# Build Lyrics Overlay.app
# Usage: bash build_app.sh
set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$PROJECT_DIR/dist/Lyrics Overlay.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RESOURCES_DIR="$APP_DIR/Contents/Resources"
PYTHON="/Users/nopgae/miniforge3/bin/python3"

echo "Building Lyrics Overlay.app..."

# Create bundle structure
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

# Copy the lyrics_overlay package into the bundle (avoids ~/Documents TCC restriction)
rm -rf "$RESOURCES_DIR/lyrics_overlay"
cp -r "$PROJECT_DIR/lyrics_overlay" "$RESOURCES_DIR/"

# Write the Python launcher (loaded from inside the bundle)
cat > "$RESOURCES_DIR/launcher.py" << 'PYEOF'
import sys
import os

resources = os.path.dirname(os.path.abspath(__file__))
if resources not in sys.path:
    sys.path.insert(0, resources)

from lyrics_overlay.main import main
main()
PYEOF

# Write the shell launcher (bundle executable)
cat > "$MACOS_DIR/Lyrics Overlay" << SHEOF
#!/bin/bash
# Launcher for Lyrics Overlay
SCRIPT_DIR="\$(dirname "\$0")"
RESOURCES="\$SCRIPT_DIR/../Resources"
exec "$PYTHON" "\$RESOURCES/launcher.py"
SHEOF
chmod +x "$MACOS_DIR/Lyrics Overlay"

# Write Info.plist
cat > "$APP_DIR/Contents/Info.plist" << 'PLISTEOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Lyrics Overlay</string>
    <key>CFBundleDisplayName</key>
    <string>Lyrics Overlay</string>
    <key>CFBundleIdentifier</key>
    <string>com.nopgae.lyrics-overlay</string>
    <key>CFBundleVersion</key>
    <string>0.4.0</string>
    <key>CFBundleShortVersionString</key>
    <string>0.4.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>Lyrics Overlay</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSUIElement</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Lyrics Overlay needs Apple Events access to detect YouTube Music playback.</string>
    <key>NSDocumentsFolderUsageDescription</key>
    <string>Lyrics Overlay needs access to your Documents folder to load MP3 and LRC files.</string>
</dict>
</plist>
PLISTEOF

echo "Done: $APP_DIR"
