#!/bin/bash
# Builds the app and installs it to /Applications/ScreenyPro.app.
set -euo pipefail
cd "$(dirname "$0")/.."
osascript -e 'tell application id "cz.comakers.screenypro" to quit' 2>/dev/null || true
scripts/build-app.sh release
rm -rf /Applications/ScreenyPro.app
cp -R build/ScreenyPro.app /Applications/ScreenyPro.app
echo "Installed /Applications/ScreenyPro.app"
