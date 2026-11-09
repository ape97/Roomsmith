#!/usr/bin/env bash
# The gate: build all targets, run the tests, lint Info.plist, check that no forbidden files are tracked.
# Usage: scripts/check.sh [--quick]   (--quick: build only). Scratch folder: .build-check.
# Ends with RESULT: GREEN or RESULT: RED (exit code 0 / 1). Changes nothing outside .build-check.
set -uo pipefail
cd "$(dirname "$0")/.."

QUICK=0
[[ "${1:-}" == "--quick" ]] && QUICK=1
failed=0
ok() { echo "ok:   $1"; }
fail() { echo "FAIL: $1"; failed=1; }

if swift build --scratch-path .build-check; then ok "swift build"; else fail "swift build"; fi

if (( ! QUICK )); then
  if swift test --scratch-path .build-check; then ok "swift test"; else fail "swift test"; fi
  if plutil -lint Resources/Info.plist > /dev/null; then ok "Info.plist"; else fail "Info.plist"; fi
  forbidden=$(git ls-files 2>/dev/null | awk '/(^|\/)\.private\// || /(^|\/)\.build[^\/]*\//')
  if [[ -z "$forbidden" ]]; then ok "no forbidden tracked files"; else fail "forbidden files are tracked:"; echo "$forbidden"; fi
fi

if (( failed )); then echo; echo "RESULT: RED"; exit 1; fi
echo; echo "RESULT: GREEN"
