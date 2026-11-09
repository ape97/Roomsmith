#!/usr/bin/env bash
# Builds the release bundle, quits a running Roomsmith, installs it to /Applications (like StatsControl) and starts it.
# Usage: scripts/deploy.sh [--no-open]
set -euo pipefail
cd "$(dirname "$0")/.."

OPEN=1
for arg in "$@"; do
  case "$arg" in
    --no-open) OPEN=0 ;;
    *) echo "usage: scripts/deploy.sh [--no-open]" >&2; exit 2 ;;
  esac
done

./scripts/bundle.sh release

TARGET=/Applications/Roomsmith.app
if pgrep -x Roomsmith > /dev/null; then
  # Never kill a running app: it may hold unsaved work. Ask it to quit and wait.
  osascript -e 'quit app "Roomsmith"' > /dev/null 2>&1 || true
  for _ in {1..40}; do pgrep -x Roomsmith > /dev/null || break; sleep 0.5; done
  if pgrep -x Roomsmith > /dev/null; then
    echo "ABORTED: Roomsmith is still running after 20 s (unsaved work or a save dialog?). Quit it manually and run again." >&2
    exit 1
  fi
fi
# Copy next to the destination first, then swap, so a failed copy never leaves /Applications without an app.
NEW="$TARGET.new.$$"
OLD="$TARGET.old.$$"
rm -rf "$NEW" "$OLD"
if ! ditto build/Roomsmith.app "$NEW"; then
  rm -rf "$NEW"
  echo "ABORTED: copying the new app failed; the installed app was not touched." >&2
  exit 1
fi
if [[ -e "$TARGET" ]]; then mv "$TARGET" "$OLD"; fi
if ! mv "$NEW" "$TARGET"; then
  [[ -e "$OLD" ]] && mv "$OLD" "$TARGET"
  echo "ABORTED: could not move the new app into place; the old app was restored." >&2
  exit 1
fi
rm -rf "$OLD"
echo "Roomsmith installed: $TARGET"
if (( OPEN )); then
  open "$TARGET"
  sleep 2
fi
./scripts/status.sh
