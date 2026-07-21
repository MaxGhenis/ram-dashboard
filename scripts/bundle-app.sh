#!/bin/bash
# Assemble dist/Rambar.app from the SPM-built RambarFace binary.
# Usage: scripts/bundle-app.sh [debug|release]
set -euo pipefail

configuration="${1:-release}"
root="$(cd "$(dirname "$0")/.." && pwd)"
binary="$root/.build/$configuration/RambarFace"
app="$root/dist/Rambar.app"

if [[ ! -x "$binary" ]]; then
    echo "build first: swift build -c $configuration" >&2
    exit 1
fi

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/Rambar"

cat > "$app/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Rambar</string>
    <key>CFBundleIdentifier</key><string>com.maxghenis.rambar</string>
    <key>CFBundleName</key><string>Rambar</string>
    <key>CFBundleDisplayName</key><string>Rambar</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>2.0.0</string>
    <key>CFBundleVersion</key><string>2.0.0</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$app"
echo "bundled $app"
