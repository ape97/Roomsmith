#!/usr/bin/env bash
# Converts a screen recording or a folder of frames into a small palette GIF with ffmpeg.
# Usage: scripts/gif.sh <input.mov|frames-dir> <out.gif> [fps] [width]   (defaults: 15 fps, 960 px wide)
# Optional environment: GIF_COLORS (palette size, default 256) and GIF_DITHER (paletteuse dither, default
# bayer:bayer_scale=5; "none" gives much smaller files for textured 3D frames).
# A frames folder holds either an ffmpeg concat list named frames.txt or numbered PNGs (*.png, sorted by name).
set -euo pipefail
ORIG="$PWD"
cd "$(dirname "$0")/.."

if (( $# < 2 )); then
  echo "usage: scripts/gif.sh <input.mov|frames-dir> <out.gif> [fps] [width]" >&2
  exit 2
fi
command -v ffmpeg > /dev/null || { echo "ffmpeg not found (brew install ffmpeg)" >&2; exit 1; }

abs() { case "$1" in /*) echo "$1" ;; *) echo "$ORIG/$1" ;; esac; }
IN=$(abs "$1")
OUT=$(abs "$2")
FPS="${3:-15}"
WIDTH="${4:-960}"
COLORS="${GIF_COLORS:-256}"
DITHER="${GIF_DITHER:-bayer:bayer_scale=5}"

if [[ -d "$IN" ]]; then
  if [[ -f "$IN/frames.txt" ]]; then
    ARGS=(-f concat -safe 0 -i "$IN/frames.txt")
  else
    ARGS=(-framerate "$FPS" -pattern_type glob -i "$IN/*.png")
  fi
elif [[ -f "$IN" ]]; then
  ARGS=(-i "$IN")
else
  echo "input not found: $IN" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT")"
ffmpeg -v error -y "${ARGS[@]}" -map_metadata -1 \
  -vf "fps=$FPS,scale=$WIDTH:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=$COLORS:stats_mode=diff[p];[b][p]paletteuse=dither=$DITHER:diff_mode=rectangle" \
  -loop 0 "$OUT"
ls -l "$OUT"
