#!/bin/sh
# Builds a release BetBaconer.app into ./dist (ad-hoc signed, runnable from Finder/Dock).
set -eu

cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="dist/BetBaconer.app"
VERSION="${VERSION:-0.9.0}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/BetBaconer" "$APP/Contents/MacOS/BetBaconer"
cp -R "$BIN_DIR/BetBaconer_BetBaconer.bundle" "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>BetBaconer</string>
    <key>CFBundleDisplayName</key><string>BetBaconer</string>
    <key>CFBundleIdentifier</key><string>de.lukasvoeller.betbaconer</string>
    <key>CFBundleExecutable</key><string>BetBaconer</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
echo "Gebaut: $APP"
