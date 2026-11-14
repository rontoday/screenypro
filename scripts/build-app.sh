#!/bin/bash
# Builds build/ScreenyPro.app from the SwiftPM package (no Xcode needed).
# Usage: scripts/build-app.sh [debug|release]   (default: release)
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
swift build -c "$CONFIG" --product ScreenyPro
BIN="$(swift build -c "$CONFIG" --show-bin-path)/ScreenyPro"
APP="build/ScreenyPro.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ScreenyPro"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# A stable signing identity keeps macOS privacy permissions between rebuilds.
# Without it the app is ad-hoc signed and macOS asks for permissions again after each rebuild.
IDENTITY="${SCREENYPRO_SIGN_IDENTITY:-ScreenyPro Dev}"
if security find-identity -p codesigning | grep -q "$IDENTITY"; then
  codesign --force --deep --sign "$IDENTITY" "$APP"
  echo "Signed with identity: $IDENTITY"
else
  codesign --force --deep --sign - "$APP"
  echo "Signed ad-hoc (no '$IDENTITY' identity found)"
fi
echo "Built $APP"
