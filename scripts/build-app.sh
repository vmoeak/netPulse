#!/bin/bash
# Builds the NetPulse.app bundle from the Swift package.
#
# Usage: scripts/build-app.sh [debug|release]
#
# Produces dist/NetPulse.app, ad-hoc code signed (signed with "-", no
# Developer ID) so it will run locally but Gatekeeper will warn on first
# launch on another Mac ("right-click > Open" to bypass, or replace the
# codesign identity below with a real Developer ID for real distribution).
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN=".build/$CONFIG/NetPulse"
APP="dist/NetPulse.app"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/NetPulse"
cp "Sources/NetPulse/Resources/Info.plist" "$APP/Contents/Info.plist"

# .icns is generated rather than checked in, from the 1024pt master that
# scripts/make-icon.py draws. Needs macOS (sips/iconutil), which is also the
# only place this script runs.
echo "==> generating NetPulse.icns"
ICONSET="$(mktemp -d)/NetPulse.iconset"
mkdir -p "$ICONSET"
for spec in 16:16x16 32:16x16@2x 32:32x32 64:32x32@2x 128:128x128 \
            256:128x128@2x 256:256x256 512:256x256@2x 512:512x512 1024:512x512@2x; do
  px="${spec%%:*}"
  name="${spec##*:}"
  sips -z "$px" "$px" "Sources/NetPulse/Resources/AppIcon.png" \
    --out "$ICONSET/icon_$name.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/NetPulse.icns"

echo "==> ad-hoc codesigning with entitlements"
codesign --force --deep --sign - \
  --entitlements "Sources/NetPulse/Resources/NetPulse.entitlements" \
  "$APP"

echo "==> done: $APP"
