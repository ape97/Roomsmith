#!/usr/bin/env bash
# Window pictures of the app (app-light, app-dark, library, workspace, settings-walk, photo-sheet)
# inspector, agent panel and presenter come from ROOMSMITH_SNAPSHOT_PANE (offscreen panes); sheets and the glass look are approximated.
# Usage: scripts/make-windows.sh <Roomsmith.app> <project.roomsmith> <second-project.roomsmith> <out-dir>
# Every picture is one hidden test-mode launch (`open -g -j -n`, no window comes to the front) that writes its own windows
# through ROOMSMITH_SNAPSHOT and quits. <project> is the refined demo that `make-media.py --keep` saves; the second
# project only fills the right-hand workspace of the comparison picture.
set -euo pipefail
APP="$1"; PROJECT="$2"; SECOND="$3"; OUT="$4"
TMP=$(mktemp -d /tmp/rsc-win.XXXXXX)
mkdir -p "$OUT" "$TMP/support"

shoot() { # <name> <expected file suffix> <appearance> [VAR=value ...]
  local name="$1" suffix="$2" appearance="$3"; shift 3
  local file="$TMP/$name$suffix"
  local envs=(ROOMSMITH_TEST_MODE=1 "ROOMSMITH_SOCKET=$TMP/s" "ROOMSMITH_SUPPORT_DIR=$TMP/support" "ROOMSMITH_OPEN=$PROJECT"
              "ROOMSMITH_SNAPSHOT=$TMP/$name" ROOMSMITH_WINDOW_SIZE=1440x900 "ROOMSMITH_APPEARANCE=$appearance" "$@")
  local args=() v
  for v in "${envs[@]}"; do args+=(--env "$v"); done
  rm -f "$file"
  open -g -j -n "${args[@]}" "$APP"
  for _ in $(seq 1 90); do [[ -f "$file" ]] && break; sleep 1; done
  [[ -f "$file" ]] || { echo "no picture: $name" >&2; return 1; }
  sleep 2; cp "$file" "$OUT/$name.png"
}

shoot app-light -0.png light ROOMSMITH_HIDE=inspector
shoot app-dark -0.png dark ROOMSMITH_HIDE=inspector
shoot library -0.png light ROOMSMITH_SIDEBAR_TAB=catalog "ROOMSMITH_LIBRARY_COLLAPSE=In this project,My furniture" ROOMSMITH_HIDE=inspector
shoot workspace -0.png light "ROOMSMITH_OPEN_COMPARE=$SECOND" ROOMSMITH_HIDE=inspector
shoot settings-walk -settings-walk.png light ROOMSMITH_SNAPSHOT_SETTINGS=walk
shoot photo-sheet -sheet-photo.png light ROOMSMITH_SNAPSHOT_SHEET=photo
shoot inspector -pane-inspector.png light ROOMSMITH_SELECT=first ROOMSMITH_SNAPSHOT_PANE=inspector
shoot presenter-airplay -pane-presenter.png light ROOMSMITH_SNAPSHOT_PANE=presenter
# The agent panel prints the app path and socket path: shoot it from a neutral copy (for example /tmp/rs/Roomsmith.app)
# with ROOMSMITH_SOCKET=/tmp/rs/s and ROOMSMITH_SNAPSHOT_PANE=agent so no home folder ends up in the picture.
rm -rf "$TMP"
