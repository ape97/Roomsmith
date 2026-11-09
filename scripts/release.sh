#!/usr/bin/env bash
# Builds the downloadable release zip. Does NOT upload, tag or push: it only prints the commands for a human.
# Usage: scripts/release.sh <version>   (plain numeric, e.g. 0.2.0)
# Needs a clean git tree and a green scripts/check.sh. Writes VERSION, build/Roomsmith-<version>.zip and .sha256.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "usage: scripts/release.sh <version>   (e.g. 0.2.0)" >&2
  exit 2
fi

if [[ -n "$(git status --porcelain)" ]]; then
  echo "RESULT: RED (git tree is not clean; commit or stash first)" >&2
  exit 1
fi
CHECK=$(./scripts/check.sh) || { echo "$CHECK" | tail -20; echo "RESULT: RED (scripts/check.sh is not green)" >&2; exit 1; }

ROOMSMITH_VERSION="$VERSION" ./scripts/bundle.sh release

ZIP="build/Roomsmith-$VERSION.zip"
rm -f "$ZIP" "$ZIP.sha256"
ditto -c -k --sequesterRsrc --keepParent build/Roomsmith.app "$ZIP"
(cd build && shasum -a 256 "Roomsmith-$VERSION.zip" > "Roomsmith-$VERSION.zip.sha256")
cat "$ZIP.sha256"

# Written last: VERSION changes only after the check, bundle and zip all succeeded.
echo "$VERSION" > VERSION

cat <<MSG

RESULT: GREEN  ($ZIP)

Nothing was uploaded or pushed. To publish, a human would run:
  git add VERSION && git commit -m "Roomsmith $VERSION"
  git tag -a v$VERSION -m "Roomsmith $VERSION"
  git push origin main v$VERSION
  gh release create v$VERSION $ZIP $ZIP.sha256 --title "Roomsmith $VERSION" --notes "..."
MSG
