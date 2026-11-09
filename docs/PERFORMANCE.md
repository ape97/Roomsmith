# Performance

Roomsmith is measured on a generated stress project: 110 walls, 48 rooms, 1000 pieces of furniture and 20 groups
(`Sources/RoomsmithCore/Benchmark/BenchmarkProject.swift`). The numbers below are produced by the `Benchmark` test suite
in a release build and written into this file by the script:

```sh
scripts/benchmark.sh          # core numbers (model, file format, geometry, commands, exports)
scripts/benchmark.sh --app    # also launches the app on the stress project and the demo apartment (scene numbers, frame times)
```

## Core

<!-- BENCH:BEGIN -->
Measured 2026-11-08 on Apple M4 Pro, macOS 27.0.1, release build.

| Measurement | Value |
|---|---:|
| Generate stress project (110 walls, 48 rooms, 1000 furniture, 20 groups) | 2.15 ms |
| Validate the whole project | 0.55 ms |
| Save .roomsmith package | 2.17 ms |
| Size of project.md | 287.95 KB |
| Load .roomsmith package | 7.63 ms |
| Wall outlines (joins) for all walls | 0.13 ms |
| Wall meshes incl. openings | 0.81 ms |
| Collision check, all objects | 3.81 ms |
| Collision check, one moved object | 0.45 ms |
| Move command (diff, validate, undo, event), median | 0.51 ms |
| Move command, slowest of 20 | 0.68 ms |
| Undo one command | 0.29 ms |
| Export plan as SVG | 177.80 ms |
| Furniture meshes, all 1000 pieces | 53.25 ms |
| Furniture vertices | 834144 count |
| Export scene as OBJ | 915.62 ms |
<!-- BENCH:END -->

## App

Measured with the release app opened on the same stress project (`ROOMSMITH_TEST_MODE=1 ROOMSMITH_BENCHMARK=1`),
2026-11-08, Apple M4 Pro, macOS 27.0.1:

| Measurement | Value |
|---|---:|
| Build the stress project in the app | 297 ms |
| First full 3D scene build (9582 entities) | 286 ms |
| Memory (resident) with plan and 3D view open | 300 MB |
| 3D frame time, stress project (1000 pieces), 1920 x 1080, median / 95th percentile | 50.0 ms / 52.7 ms (20 fps) |
| 3D frame time, demo apartment (30 pieces), 1920 x 1080, median / 95th percentile | 3.0 ms / 4.1 ms (330 fps) |
| 3D frame time, empty scene (fixed cost per frame) | 0.9 ms |
| Live 3D view in the visible window, demo apartment (337 entities), frames per second over ~3 s | 94 fps |
| Live 3D view in the visible window, stress project (9582 entities), frames per second over ~3 s | 27.5 fps |

The frame times come from the `ROOMSMITH_RENDER` line: the app renders the same RealityKit scene as its 3D view
offscreen, 120 frames one after another, each timed from submitting the frame (scene update plus render) to its
completion. Frames are not
overlapped, so this is a conservative figure. It works with the window hidden or covered, where the live view itself
gets no frames (its own `fps=` in the `ROOMSMITH_SCENE` line then reads `n/a`). The demo apartment row comes from
`ROOMSMITH_RENDER_BENCH=1` with `ROOMSMITH_OPEN` set to a copy of `Examples/Demo Apartment.roomsmith`;
`scripts/benchmark.sh --app` runs both.
The two live rows come from the `fps=` field of the `ROOMSMITH_SCENE` line with the app launched in front
(`ROOMSMITH_BENCHMARK=1`, window content 1600 x 1000 points); they count frames the window actually showed in the
first ~3 s after the scene was built, so they include the settling after launch.
The empty-scene row and the 480 x 270 comparison below were measured once with a modified build (scene removed after setup, smaller render size); they are not part of the script.

## What the numbers mean

- Editing stays interactive: a move command including validation, undo record and change event takes under 1 ms, and
  the collision check after a move under 1 ms, so dragging one piece in a 1000-piece project costs far less than one
  frame at 120 Hz.
- Opening and saving a 1000-piece project takes about 8 ms and 4 ms; `project.md` is under 300 KB.
- A typical apartment draws in about 3 ms per frame at full HD, far inside the 60 fps target (16.7 ms) and inside
  120 Hz (8.3 ms). Resolution hardly matters (the stress project at 480 x 270 takes 48 ms instead of 50 ms); the cost
  grows with the number of pieces (scene update and draw calls), not with the pixels. The 1000-piece stress project,
  more than thirty times the demo apartment, still draws at about 20 fps; drawing identical pieces as instances is the next step if projects of that size become common.
- The slow paths are whole-project exports: SVG of the full plan about 0.3 s, an OBJ of all 834 144 furniture vertices
  about 1.4 s. Both run once per export.
