#!/bin/bash
# Builds a real, double-clickable "ISS PISS-O-METER.app" menu-bar bundle.
# Requires the Xcode Command Line Tools (xcode-select --install) and macOS 12+.
set -euo pipefail
cd "$(dirname "$0")"

APP="ISS PISS-O-METER.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>ISS PISS-O-METER</string>
  <key>CFBundleDisplayName</key><string>ISS PISS-O-METER</string>
  <key>CFBundleIdentifier</key><string>com.mattarvon.isspissometer</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>IssPissOMeter</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "Compiling…"
swiftc -O -framework AppKit -o "$APP/Contents/MacOS/IssPissOMeter" IssPissOMeter.swift

# Ad-hoc sign so locally-launched app runs cleanly under Gatekeeper.
codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "Built \"$APP\"."
echo "Drag it to /Applications and open it (right-click → Open the first time)."
echo "To auto-start: System Settings → General → Login Items → add the app."
