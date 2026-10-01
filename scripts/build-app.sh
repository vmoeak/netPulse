#!/bin/bash
# Builds the NetPulse.app bundle from the Swift package.
#
# Usage: scripts/build-app.sh [debug|release]
#
# Produces dist/NetPulse.app, signed with a local identity when the keychain
# has one (see below), ad hoc otherwise. Either runs locally; Gatekeeper
# warns on another Mac ("right-click > Open" to bypass) unless it is a
# notarized Developer ID build.
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

# .icns is packed from the checked-in iconset that scripts/icon/make-icon.mjs
# renders (every size drawn natively). Needs macOS (iconutil), which is also
# the only place this script runs.
echo "==> generating NetPulse.icns"
iconutil -c icns "Sources/NetPulse/Resources/AppIcon.iconset" -o "$APP/Contents/Resources/NetPulse.icns"

# A stable identity keeps macOS's privacy grants (such as access to other
# apps' data) across rebuilds; an ad-hoc signature is new every build, so
# macOS asks again each time. SIGN_IDENTITY wins, then the first valid
# code-signing identity in the keychain (an "Apple Development" certificate,
# or the local one scripts/make-signing-cert.sh creates), then ad hoc.
IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' 'NF > 1 { print $2; exit }')"
fi
if [ -n "$IDENTITY" ]; then
  echo "==> codesigning as \"$IDENTITY\""
else
  IDENTITY="-"
  echo "==> ad-hoc codesigning (run scripts/make-signing-cert.sh once to keep privacy grants across builds)"
fi
codesign --force --deep --sign "$IDENTITY" \
  --entitlements "Sources/NetPulse/Resources/NetPulse.entitlements" \
  "$APP"

echo "==> done: $APP"
