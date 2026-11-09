#!/usr/bin/env bash
# Builds build/Roomsmith.app from the SwiftPM products (app + roomsmith-mcp helper), ad-hoc signed.
# Usage: scripts/bundle.sh [debug|release]   (default: release)
# Version: VERSION file, else `git describe`, else 0.1.0. Scratch folder: .build-bundle.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
case "$CONFIG" in debug | release) ;; *) echo "usage: scripts/bundle.sh [debug|release]" >&2; exit 2 ;; esac

SCRATCH=.build-bundle
swift build -c "$CONFIG" --scratch-path "$SCRATCH" --product Roomsmith
swift build -c "$CONFIG" --scratch-path "$SCRATCH" --product roomsmith-mcp
BIN=$(swift build -c "$CONFIG" --scratch-path "$SCRATCH" --show-bin-path)

if [[ -n "${ROOMSMITH_VERSION:-}" ]]; then
  VERSION=$ROOMSMITH_VERSION   # release.sh passes the new version before it writes VERSION
elif [[ -s VERSION ]]; then
  VERSION=$(tr -d '[:space:]' < VERSION)
elif DESCRIBED=$(git describe --tags --abbrev=0 2>/dev/null); then
  VERSION=${DESCRIBED#v}
else
  VERSION=0.1.0
fi
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)

APP=build/Roomsmith.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN/Roomsmith" "$APP/Contents/MacOS/Roomsmith"
cp "$BIN/roomsmith-mcp" "$APP/Contents/Helpers/roomsmith-mcp"
# A release carries no symbol table or debug paths (they would name the build machine's folders).
if [[ "$CONFIG" == release ]]; then
  strip -Sx "$APP/Contents/MacOS/Roomsmith" "$APP/Contents/Helpers/roomsmith-mcp"
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
sed -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD/g" Resources/Info.plist > "$APP/Contents/Info.plist"

# SwiftPM resource bundles (<Package>_<Target>.bundle), if any target has resources.
shopt -s nullglob
for b in "$BIN"/*.bundle; do
  cp -R "$b" "$APP/Contents/Resources/"
done
shopt -u nullglob

plutil -lint "$APP/Contents/Info.plist" > /dev/null
# Sign the helper first, then the app around it.
codesign --force -s - "$APP/Contents/Helpers/roomsmith-mcp"
codesign --force --deep -s - "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP ($CONFIG, version $VERSION, build $BUILD)"
