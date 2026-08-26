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
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/NetPulse"
cp "Sources/NetPulse/Resources/Info.plist" "$APP/Contents/Info.plist"

echo "==> ad-hoc codesigning with entitlements"
codesign --force --deep --sign - \
  --entitlements "Sources/NetPulse/Resources/NetPulse.entitlements" \
  "$APP"

echo "==> done: $APP"
