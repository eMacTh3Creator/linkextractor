#!/bin/bash
# install.sh — Removes macOS quarantine and optionally copies to Applications
# Run this after downloading LinkExtractor from GitHub.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$SCRIPT_DIR/LinkExtractor.app"

if [ ! -d "$APP" ]; then
    echo "LinkExtractor.app not found in $(dirname "$0")."
    echo "Make sure this script is in the same folder as LinkExtractor.app."
    exit 1
fi

echo ""
echo "  Link Extractor — Install"
echo "  ========================"
echo ""

# Strip quarantine (the main fix)
echo "  Removing macOS quarantine flag..."
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
echo "  Done."
echo ""

# Offer to copy to Applications
read -r -p "  Copy to /Applications? [Y/n] " R
R=${R:-Y}
if [[ "$R" =~ ^[Yy]$ ]]; then
    if [ -d "/Applications/LinkExtractor.app" ]; then
        echo "  Replacing existing copy..."
        rm -rf "/Applications/LinkExtractor.app"
    fi
    cp -R "$APP" /Applications/
    xattr -dr com.apple.quarantine /Applications/LinkExtractor.app 2>/dev/null || true
    echo "  Installed to /Applications/LinkExtractor.app"
    echo ""
    read -r -p "  Launch now? [Y/n] " L
    L=${L:-Y}
    [[ "$L" =~ ^[Yy]$ ]] && open /Applications/LinkExtractor.app
else
    echo ""
    read -r -p "  Launch from current location? [Y/n] " L
    L=${L:-Y}
    [[ "$L" =~ ^[Yy]$ ]] && open "$APP"
fi

echo ""
echo "  All set!"
echo ""
