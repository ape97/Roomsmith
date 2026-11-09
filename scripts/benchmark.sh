#!/usr/bin/env bash
# P01: measures the 1000-object stress project and writes the numbers into docs/PERFORMANCE.md
# (between the BENCH markers). Core part: the "Benchmark" test suite in release mode. App part (optional,
# --app): launches build/Roomsmith.app with ROOMSMITH_BENCHMARK=1 and reads its ROOMSMITH_* stdout lines, then once
# more on a copy of the demo apartment (ROOMSMITH_RENDER_BENCH=1) for the frame time of a typical project.
# Usage: scripts/benchmark.sh [--app]   Scratch folder: .build-bench. Prints the table; exit 1 on failure.
set -uo pipefail
cd "$(dirname "$0")/.."

APP=0
[[ "${1:-}" == "--app" ]] && APP=1
DOC=docs/PERFORMANCE.md
LOG=$(mktemp -t roomsmith-bench)
trap 'rm -f "$LOG"' EXIT

echo "Building and running the core benchmark (release)…"
if ! swift test -c release --scratch-path .build-bench --filter "Benchmark" > "$LOG" 2>&1; then
  tail -40 "$LOG"
  echo "benchmark tests failed" >&2
  exit 1
fi

label() {
  case "$1" in
    make_project) echo "Generate stress project (110 walls, 48 rooms, 1000 furniture, 20 groups)|ms" ;;
    validate_all) echo "Validate the whole project|ms" ;;
    save_package) echo "Save .roomsmith package|ms" ;;
    project_md_kb) echo "Size of project.md|KB" ;;
    load_package) echo "Load .roomsmith package|ms" ;;
    wall_outlines) echo "Wall outlines (joins) for all walls|ms" ;;
    wall_meshes_all) echo "Wall meshes incl. openings|ms" ;;
    collision_all) echo "Collision check, all objects|ms" ;;
    collision_one) echo "Collision check, one moved object|ms" ;;
    command_move_one_median) echo "Move command (diff, validate, undo, event), median|ms" ;;
    command_move_one_max) echo "Move command, slowest of 20|ms" ;;
    undo_one) echo "Undo one command|ms" ;;
    export_svg) echo "Export plan as SVG|ms" ;;
    furniture_meshes_all) echo "Furniture meshes, all 1000 pieces|ms" ;;
    furniture_vertices) echo "Furniture vertices|count" ;;
    export_obj) echo "Export scene as OBJ|ms" ;;
    *) echo "$1|ms" ;;
  esac
}

TABLE="| Measurement | Value |"$'\n'"|---|---:|"
while read -r _ name value; do
  IFS='|' read -r text unit <<< "$(label "$name")"
  [[ "$unit" == count ]] && value=${value%.00}
  TABLE+=$'\n'"| $text | $value $unit |"
done < <(awk '$1 == "BENCH" { print $1, $2, $3 }' "$LOG")
if ! awk '$1 == "BENCH" { found = 1 } END { exit !found }' "$LOG"; then
  echo "no BENCH lines in the test output (filter matched nothing?)" >&2
  exit 1
fi

if (( APP )); then
  BUNDLE=build/Roomsmith.app/Contents/MacOS/Roomsmith
  [[ -x "$BUNDLE" ]] || scripts/bundle.sh release > /dev/null
  OUT=$(mktemp -t roomsmith-bench-app)
  SUPPORT=$(mktemp -d /tmp/rsb.XXXXXX)   # short: Unix socket paths are limited to 104 bytes
  ROOMSMITH_TEST_MODE=1 ROOMSMITH_BENCHMARK=1 ROOMSMITH_SUPPORT_DIR="$SUPPORT" ROOMSMITH_SOCKET="$SUPPORT/s" \
    "$BUNDLE" > "$OUT" 2>&1 &
  PID=$!
  for _ in $(seq 1 90); do
    awk '/^ROOMSMITH_RENDER/ { found = 1 } END { exit !found }' "$OUT" && break
    sleep 1
  done
  kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null
  awk '/^ROOMSMITH_SCENE/ { found = 1 } END { exit !found }' "$OUT" \
    || echo "warning: the app printed no ROOMSMITH_SCENE line within 90 s; 3D numbers are missing" >&2
  awk '/^ROOMSMITH_RENDER/ { found = 1 } END { exit !found }' "$OUT" \
    || echo "warning: the app printed no ROOMSMITH_RENDER line within 90 s; the 3D frame time is missing" >&2
  while read -r line; do
    TABLE+=$'\n'"| App: ${line#ROOMSMITH_} | |"
  done < <(awk '/^ROOMSMITH_(BENCHMARK|SCENE|RENDER)/' "$OUT")
  rm -rf "$OUT" "$SUPPORT"

  # Typical apartment: the same frame-time measurement on a copy of the demo project.
  OUT=$(mktemp -t roomsmith-bench-demo)
  SUPPORT=$(mktemp -d /tmp/rsb.XXXXXX)
  cp -R "Examples/Demo Apartment.roomsmith" "$SUPPORT/demo.roomsmith"
  ROOMSMITH_TEST_MODE=1 ROOMSMITH_RENDER_BENCH=1 ROOMSMITH_OPEN="$SUPPORT/demo.roomsmith" ROOMSMITH_SUPPORT_DIR="$SUPPORT" \
    ROOMSMITH_SOCKET="$SUPPORT/s" "$BUNDLE" > "$OUT" 2>&1 &
  PID=$!
  for _ in $(seq 1 60); do
    awk '/^ROOMSMITH_RENDER/ { found = 1 } END { exit !found }' "$OUT" && break
    sleep 1
  done
  kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null
  line=$(awk '/^ROOMSMITH_RENDER/' "$OUT")
  [[ -n "$line" ]] && TABLE+=$'\n'"| Demo apartment: ${line#ROOMSMITH_} | |" \
    || echo "warning: no ROOMSMITH_RENDER line for the demo apartment within 60 s" >&2
  rm -rf "$OUT" "$SUPPORT"
fi

STAMP="Measured $(date +%Y-%m-%d) on $(sysctl -n machdep.cpu.brand_string 2>/dev/null || uname -m), macOS $(sw_vers -productVersion), release build."
BLOCK="<!-- BENCH:BEGIN -->"$'\n'"$STAMP"$'\n\n'"$TABLE"$'\n'"<!-- BENCH:END -->"

if [[ -f "$DOC" ]] && grep -q "BENCH:BEGIN" "$DOC"; then
  BLOCK="$BLOCK" awk '
    /<!-- BENCH:BEGIN -->/ { print ENVIRON["BLOCK"]; skip = 1; next }
    /<!-- BENCH:END -->/ { skip = 0; next }
    !skip { print }' "$DOC" > "$DOC.tmp" && mv "$DOC.tmp" "$DOC"
else
  mkdir -p docs
  printf '# Performance\n\n%s\n' "$BLOCK" > "$DOC"
fi
echo "$BLOCK"
echo "Wrote $DOC"
