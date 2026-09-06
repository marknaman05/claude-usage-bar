#!/bin/bash
# Builds ClaudeUsage.app and installs it to ~/Applications.
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="ClaudeUsage"
DEST="${1:-$HOME/Applications}"
APP="$DEST/$APP_NAME.app"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>Claude Usage</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>local.claude-usage-bar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

swiftc -O \
  -target arm64-apple-macos13.0 \
  -framework AppKit -framework Security -framework ServiceManagement \
  -o "$APP/Contents/MacOS/$APP_NAME" \
  "$SRC_DIR/Sources/main.swift"

# Ad-hoc sign so the Keychain ACL sticks across launches.
codesign --force --sign - --identifier local.claude-usage-bar "$APP"

echo "Built: $APP"
