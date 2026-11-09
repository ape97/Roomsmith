#!/usr/bin/env bash
# Shows the project version, git state, whether the app runs, the agent socket and the installed copy. Changes nothing.
set -uo pipefail
cd "$(dirname "$0")/.."

if [[ -s VERSION ]]; then
  version=$(tr -d '[:space:]' < VERSION)
elif described=$(git describe --tags --abbrev=0 2>/dev/null); then
  version=${described#v}
else
  version="0.1.0 (default)"
fi
echo "Version:   $version"

if git rev-parse --git-dir > /dev/null 2>&1; then
  branch=$(git branch --show-current 2>/dev/null)
  changes=$(git status --porcelain | wc -l | tr -d ' ')
  echo "Git:       branch ${branch:-?}, $changes changed/untracked paths"
else
  echo "Git:       not a repository"
fi

if pgrep -x Roomsmith > /dev/null; then echo "Running:   yes"; else echo "Running:   no"; fi

SOCKET="${ROOMSMITH_SOCKET:-$HOME/Library/Application Support/Roomsmith/agent.sock}"
if [[ -S "$SOCKET" ]]; then echo "Agent:     socket present ($SOCKET)"; else echo "Agent:     no socket at $SOCKET"; fi

for app in /Applications/Roomsmith.app "$HOME/Applications/Roomsmith.app" "$PWD/build/Roomsmith.app"; do
  if [[ -d "$app" ]]; then
    have=$(defaults read "$app/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "?")
    if codesign --verify --deep --strict "$app" 2>/dev/null; then sig="signature valid"; else sig="signature INVALID"; fi
    echo "Installed: $app (version $have, $sig)"
  fi
done
