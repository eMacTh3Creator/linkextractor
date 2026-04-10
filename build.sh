#!/bin/bash
# build.sh — Compiles LinkExtractor.swift into a native macOS .app
# Requirements: macOS 12+, Xcode Command Line Tools

set -euo pipefail

APP_NAME="LinkExtractor"
BUNDLE="$APP_NAME.app"
BINARY="$BUNDLE/Contents/MacOS/$APP_NAME"

echo "╔══════════════════════════════════╗"
echo "║   Building $APP_NAME.app    ║"
echo "╚══════════════════════════════════╝"
echo ""

if ! command -v swiftc &>/dev/null; then
  echo "❌  swiftc not found."
  echo "    Install Xcode Command Line Tools: xcode-select --install"
  exit 1
fi

echo "✓  $(swiftc --version 2>&1 | head -1)"

# Clean
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
mkdir -p "$BUNDLE/Contents/Resources"

# Compile — links PDFKit
echo ""
echo "⚙️   Compiling (15–30 seconds)…"

swiftc \
  -O \
  -sdk "$(xcrun --show-sdk-path)" \
  -target arm64-apple-macos12.0 \
  -framework PDFKit \
  LinkExtractor.swift \
  -o "$BINARY"

echo "✓  Compiled"

# Info.plist
cat > "$BUNDLE/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>        <string>LinkExtractor</string>
    <key>CFBundleIdentifier</key>        <string>com.user.linkextractor</string>
    <key>CFBundleName</key>              <string>Link Extractor</string>
    <key>CFBundleDisplayName</key>       <string>Link Extractor</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>LSMinimumSystemVersion</key>    <string>12.0</string>
    <key>NSPrincipalClass</key>          <string>NSApplication</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>       <string>PDF Document</string>
            <key>CFBundleTypeExtensions</key> <array><string>pdf</string></array>
            <key>CFBundleTypeRole</key>       <string>Viewer</string>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>       <string>Word Document</string>
            <key>CFBundleTypeExtensions</key> <array><string>docx</string></array>
            <key>CFBundleTypeRole</key>       <string>Viewer</string>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>       <string>Pages Document</string>
            <key>CFBundleTypeExtensions</key> <array><string>pages</string></array>
            <key>CFBundleTypeRole</key>       <string>Viewer</string>
        </dict>
    </array>
</dict>
</plist>
PLIST

xattr -dr com.apple.quarantine "$BUNDLE" 2>/dev/null || true

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║  ✅  LinkExtractor.app is ready!                     ║"
echo "║                                                      ║"
echo "║  Drag to Applications or double-click to run now.    ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

read -r -p "Launch now? [Y/n] " R
R=${R:-Y}
[[ "$R" =~ ^[Yy]$ ]] && open "$BUNDLE"
