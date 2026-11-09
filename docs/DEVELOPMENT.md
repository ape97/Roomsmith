# Development

Everything you need to change, build, install and release Roomsmith yourself.

## Prerequisites

- macOS 26 or later on Apple silicon
- Swift 6 toolchain (Xcode 26 or later, or the matching command line tools); the project is a plain SwiftPM package
- Optional: `ffmpeg` for `scripts/gif.sh` (`brew install ffmpeg`)

There is no Xcode project; open `Package.swift` in Xcode if you want an IDE, or work from the terminal.

## Targets

| Target | Kind | Purpose |
|---|---|---|
| `RoomsmithCore` | library | Document model, geometry, commands, persistence, import/export and the agent tool API. Foundation and CoreGraphics only: no AppKit, no RealityKit. |
| `RoomsmithIPC` | library | Local agent transport: Unix domain socket, newline-delimited JSON. |
| `Roomsmith` | executable | The macOS app (SwiftUI, AppKit, RealityKit). |
| `roomsmith-mcp` | executable | MCP stdio server and command line client that talks to the running app. |
| `RoomsmithCoreTests` | tests | Unit tests for core and IPC. |

```
Package.swift
Sources/        RoomsmithCore, RoomsmithIPC, Roomsmith, roomsmith-mcp
Tests/          RoomsmithCoreTests
Resources/      Info.plist template (__VERSION__ / __BUILD__ placeholders), AppIcon.icns
scripts/        check, bundle, deploy, status, release, gif, icon
docs/           user and contributor documentation, notes for AI agents, images/ (README pictures)
```

## Scripts

All scripts can be started from any folder.

| Script | What it does |
|---|---|
| `scripts/check.sh [--quick]` | The gate. Builds all targets, runs the tests, lints `Resources/Info.plist` and verifies that no forbidden files (`.private/`, `.build*`) are tracked. `--quick` only builds. Ends with `RESULT: GREEN` or `RESULT: RED`. |
| `scripts/bundle.sh [debug\|release]` | Builds `build/Roomsmith.app` (default `release`) with the helper in `Contents/Helpers/roomsmith-mcp`, ad-hoc signed and verified. |
| `scripts/deploy.sh [--no-open]` | Bundles a release build, quits a running instance, installs to `/Applications/Roomsmith.app` and starts it. |
| `scripts/status.sh` | Shows version, git state, whether the app runs, the agent socket and the installed copy. Changes nothing. |
| `scripts/release.sh <version>` | Needs a clean git tree and a green check. Writes `VERSION`, builds `build/Roomsmith-<version>.zip` and its `.sha256`. Uploads and pushes nothing; it prints the `git` and `gh` commands to run by hand. |
| `scripts/gif.sh <input.mov\|frames-dir> <out.gif> [fps] [width]` | Palette GIF from a recording or a folder of frames (needs `ffmpeg`). |
| `swift scripts/icon.swift` | Draws the app icon to `docs/images/icon.png` and builds `Resources/AppIcon.icns` with `iconutil`. Run from the repository root. |

Typical loop: edit, `scripts/check.sh`, then `scripts/deploy.sh` to use it.

## Scratch folders

Every script that builds uses its own SwiftPM scratch folder, so parallel runs and an open Xcode or `swift build` session
never lock each other:

| Folder | Used by |
|---|---|
| `.build/` | plain `swift build` / `swift test` by hand |
| `.build-check/` | `scripts/check.sh` |
| `.build-bundle/` | `scripts/bundle.sh`, `deploy.sh`, `release.sh` |

All `.build*/` folders and `build/` are git-ignored. Use `--scratch-path .build-<purpose>` for your own experiments.

## Launch environment

For tests and screenshots (unbundled binary):

- `ROOMSMITH_TEST_MODE=1`: test mode (exactly `1`; any other value is off). `ROOMSMITH_SUPPORT_DIR`, `ROOMSMITH_SOCKET`: see Agent API.
- Only under test mode (otherwise ignored, so a stray variable cannot change the real settings or open files):
  `ROOMSMITH_LAYOUT=split|plan|scene` (initial editor layout), `ROOMSMITH_OPEN=<file>` (open a project on launch; with `ROOMSMITH_OPEN_COMPARE=<file>` a second project opens as a tab and is shown next to the first in the compare split, `ROOMSMITH_COMPARE_STACKED=1` stacks them),
  `ROOMSMITH_BENCHMARK=1` (open the generated stress project), the `ROOMSMITH_SCENE_SELECT|SNAPSHOT|OFFSCREEN` and `ROOMSMITH_PERF_PROBE` hooks below
  and the hooks in `App/TestHooks.swift`. `scripts/benchmark.sh` sets test mode itself.
- Last session and Open Recent: the app writes `session.json` (open tabs, active tab, split) and `recent.json` into the support
  folder and reopens the session on a normal launch. Under test mode neither file is read or written unless
  `ROOMSMITH_RESTORE_SESSION=1` is set (use it together with your own `ROOMSMITH_SUPPORT_DIR`); `ROOMSMITH_OPEN` and
  `ROOMSMITH_BENCHMARK` launches never restore a session.
- Plan/3D arrangement is the user default `editorSplitAxis` (`sideBySide` or `stacked`). In a normal run
  `-editorSplitAxis stacked` on the command line overrides it for one run without writing it. Under test mode the
  setting lives in a separate defaults suite, which the command-line argument does not reach; there the arrangement
  starts as side by side (switch it through the View menu).

## Version

`VERSION` (plain text, for example `0.2.0`) wins; without it the latest git tag is used, and without a tag `0.1.0`.
`scripts/release.sh` writes the file. The build number is the commit count.

## Agent API

The running app offers its document tools to local agents over a Unix domain socket with newline-delimited JSON.

- Socket: `~/Library/Application Support/Roomsmith/agent.sock`
- Token: `~/Library/Application Support/Roomsmith/agent-token`; every request carries it
- Audit log: `~/Library/Application Support/Roomsmith/agent-audit.jsonl`
- Overrides: `ROOMSMITH_SUPPORT_DIR`, `ROOMSMITH_SOCKET`, `ROOMSMITH_TOKEN_FILE`
- `roomsmith-mcp` is the client: it speaks MCP over stdio for agent hosts and reaches the app through the socket. The
  app must be running. In the bundle it lives at `Roomsmith.app/Contents/Helpers/roomsmith-mcp`.

Protocol types are in `Sources/RoomsmithCore/Agent/`, the transport in `Sources/RoomsmithIPC/`.

## Signing

Bundles are ad-hoc signed (`codesign -s -`), so no developer account is needed. Gatekeeper will ask for confirmation the
first time a downloaded build is opened (right-click, Open).

## Releasing

1. Commit everything; `scripts/check.sh` must be green.
2. `scripts/release.sh 0.2.0` builds `build/Roomsmith-0.2.0.zip` and the checksum.
3. Commit `VERSION`, tag and publish by hand, for example:
   ```sh
   git tag -a v0.2.0 -m "Roomsmith 0.2.0" && git push origin main v0.2.0
   gh release create v0.2.0 build/Roomsmith-0.2.0.zip build/Roomsmith-0.2.0.zip.sha256 --title "Roomsmith 0.2.0" --notes "…"
   ```

## Trackpad and mouse

### Plan

| Input | Action |
|---|---|
| Two-finger scroll | Pan (momentum included) |
| Pinch | Zoom around the pointer (per-event factor clamped to 0.2...5, scale limits respected) |
| Two-finger rotate | Rotate the selection (furniture, groups, walls, rooms, dimensions) around its centre; live preview with degree tag, one undo step "Rotate" at the end, a cancelled gesture restores; snaps to the angle step (15 degrees by default) unless ⌥ is held or snap is off; no-op without selection |
| Smart zoom (two-finger double tap) | Fit the selection, or everything |
| ⌘ + scroll | Zoom around the pointer |
| Mouse wheel (no precise deltas) | Zoom in fixed steps of 1.2 |
| ⇧ + mouse wheel | Pan horizontally |
| Middle button drag / Space + drag | Pan |
| Hand tool (toolbar next to Select, key H; V returns to Select, Esc too) | Left drag pans; clicks select nothing, drags edit nothing, Delete and the nudge/rotate keys do nothing. Open hand cursor, closed hand while dragging. The tool is app state (`AppModel.tool`), not saved in the project |

The Measure tool works in the plan and in the 3D view (not in first person). In 3D two clicks pick surface points (the nearest hit, else the ground at the active level height), `Measure3DState` (`Sources/RoomsmithCore/Interaction/Measure3D.swift`, tests `Measure3DTests`) keeps A and B (a third click starts anew, Esc clears, a second Esc returns to Select), `Measurement3D` gives the distance (text via `DistanceText`, shared with the plan) and dx/dy/dz in mm (X east, Y north, Z up). `SceneMeasureOverlay` (`SceneRenderer+Measure.swift`) is a non-hit-testing view above the ARView that projects the world points with the camera every frame, so the line and label stay on the points and are drawn on top; while the tool is active clicks neither select nor move (`SceneRenderer.allowsEditing`) and a drag still orbits. `EditorTool.isAvailable(in:)` decides which tools work per layout: in the 3D-only layout only Select, Hand and Measure; the toolbar `ToolPicker` greys the others (help text names the plan view), and `ContentView` falls back to Select when the active tool becomes unavailable. The hosted tests of this tool run serialized: parallel hosted windows and the async model observation (`observeModel`) interfere.

The look-only rules of the Hand tool and Space (plan and 3D view) are `HandMode` (`Sources/RoomsmithCore/Interaction/HandMode.swift`, tests in `HandModeTests`); the plan pans with its existing Space/middle-button pan, the 3D view routes the press to its camera drag (`SceneRenderer.handActive`, `allowsEditing`). Plain-letter shortcuts H and V are handled in the key handlers of the plan and the 3D view (never as menu shortcuts, so typing in text fields is not affected). The Hand tool only looks at mouse input: the Arrange menu (⌘⌫, ⌘D, ⌘G, ⌘L, ⌘[ ⌘]) keeps working on the selection on purpose, and a library drop still places furniture (explicit drag and drop). A press made in Hand mode (`PendingClick.handPress`) never selects, even when Space is released before the mouse button.

Pinch, rotate and smart zoom are ignored while a mouse button is down (drag, handle drag, marquee). The math lives in `PlanGesture` (`Sources/RoomsmithCore/Geometry/PlanGesture.swift`, tests in `PlanGestureTests`).

### 3D view

| Input | Orbit / Aerial | Top | Free | First person |
|---|---|---|---|---|
| Two-finger scroll | Orbit around the target | Pan | Look around | Look around |
| ⇧ + two-finger scroll | Pan | Pan | Slide (in the view plane) | Pan |
| Pinch | Zoom toward the pointer (the picked surface, else the ground at target height stays under it) | same | Fly along the ray under the pointer | Walk forward / back |
| Two-finger rotate | Yaw around the target | same | Turn on the spot | same as Orbit |
| Smart zoom (two-finger double tap) | Frame the selection, else everything | same | Look at the selection / everything from here | same as Orbit |
| ⌘ + scroll, mouse wheel (no precise deltas) | Zoom toward the pointer | same | Fly along the ray | Walk |
| Drag on empty space (also three-finger drag) | Orbit (⇧ pans) | Pan (⇧ orbits) | Look (⇧ slides) | Look (⇧ pans) |
| Right / middle button drag | Pan | Pan | Slide | Pan |
| Click / ⇧ click | Select / toggle selection | same | same | Nothing (no selection, no gizmo; a click captures the mouse) |
| Hand tool (key H) or Space held | Look only: left drag moves the camera as "Drag on empty space" (⇧ as there); no click selection, no hover, no gizmo, no furniture drag, Delete does nothing; open hand cursor, closed hand while dragging. V or Esc returns to Select. Not in first person (there the click still captures the mouse) | same | same | same |
| Drag a selected piece of furniture or group (selection of furniture and groups only) | Move over the floor, see below | same | same | not in first person |
| Keys | | | W S forward / back along the view, A D sideways, E up, Q down, ⇧ faster (3x), ⌥ slower (0.3x) | W S or ↑ ↓ walk, A D sideways, ← → turn, C crouch, E opens the door in view, ⇧ faster, ⌥ slower, Space held walks through walls and furniture (eye height 1600 mm) |

**Free** is the fly camera: like first person the `target` of the stored camera is the eye (`CameraRig.eyeIsTarget`), but
there is no collision, no floor and no eye-height snap. W A S D fly along the view direction (pitch included), Q E move
straight down / up, at 2.5 m/s; the velocity eases in and out (time constant 0.12 s, independent of the frame rate;
`FreeFlight` in `RoomsmithCore`, driven by `SceneRenderer.tickFlight`). Editing stays possible: the gizmo, selection and
hover work as in Orbit. Switching rules (`SceneCameraController.setMode`): Orbit or Top to Free keeps the eye, heading and
pitch (pitch is limited to ±89°); Top to Free changes the field of view from the narrow top lens to the normal one. Free
to Orbit puts the orbit target on the surface in the middle of the view (3 m ahead when nothing is there), so the eye does
not move; Free to Top fits the content like Frame; Free to First person keeps the position on the floor plan and stands up
to eye height. The stored orbit pose for the way back from First person never holds a Free pose.

**Space in First person** switches the walk collision off for as long as it is held (`WalkPassThrough`, `Sources/RoomsmithCore/Walk/WalkPassThrough.swift`, applied in `WalkController.tick`; Space lands in `pressedKeys`, the temporary Hand does not apply there). It is not a setting and creates no document or undo entry. `keyUp` always removes the key from `pressedKeys` (also when it ends the temporary Hand); `releaseInput` runs only when the 3D view loses focus or its window stops being key; a switch to First person (`setViewMode`, then `modeDidChange`) clears `pressedKeys` and a held temporary Hand (`spaceHeld`). On release inside a wall or furniture the walker is pushed out to the nearest free spot (`WalkCollider.resolve`). A disabled "collision" setting stays disabled. Free has no collision anyway.

In **First person** the gizmo, the selection tint and the hover tint are off (the selection itself stays and the Inspector
still shows it); a running gizmo drag is cancelled when the mode changes. They come back with Orbit, Free and Top. This
also applies to `render.scene_image` pictures taken in First person.

Gizmo (shown for a movable, unlocked selection): X red, Y green, Z blue arrows (Z only for furniture and groups) and a
rotation ring. Axis drags snap to the grid in the project settings, ring drags to the angle step; ⌥ suspends snapping.
The Z arrow of furniture is drawn onto the tops of other furniture under the piece (at any height, partial overlap is
enough), against undersides above it and onto the floor, within the contact tolerance; the HUD then says "touching".
The entities show a live preview and the document changes once, at release, as one undoable command ("Move" or
"Rotate"); Esc cancels. The pointer HUD shows the delta in mm or degrees.
With nothing running to cancel (no drag, no undecided press), Esc clears the selection: in the 3D view itself and, through a
window-level fallback (`EscapeClearsSelection`), when the focus sits on another control. Not in text fields, not with
modifier keys, not in a window with a sheet, not in walk mode.

Axis drags of furniture and groups (X and Y) also use the contact stop described next, but stay on their line: the piece
stops flush where it would touch, never slides off the axis.

Moving furniture over the floor in 3D: press on a piece that is already selected and drag past the click slop (a press on
an unselected piece or on empty space still drags the camera: click first, then drag). The cursor ray meets the plane
of the piece's lower edge; rays nearly parallel to the floor (|dir.z| < 0.05) or pointing away keep the last valid
position, the distance is clamped to 50 m. The piece stops flush at walls (below wall height, door and window openings
only where the collision check reports them, door swings) and at furniture that overlaps in height, slides along the
touched face, is pulled flush when it ends within the snap tolerance of a face (about 9 points on screen, 20 to 300 mm,
at most the project's snap tolerance), and goes through an obstacle when pushed about 200 mm beyond the touching position
(stateless: pulling back below that snaps again). Walls follow "Snap to walls", furniture "Snap to objects". ⌥ or snap
off disables all of it. Free pieces (`allowsOverlap` or flat floor pieces) neither stop nor are stopped. The entities
show a live preview, the HUD shows the offset, the document changes once at release ("Move"); Esc cancels. The rules
live in `MoveContact` (`Sources/RoomsmithCore/Geometry/MoveContact.swift`, tests `MoveContactTests`), the obstacles are
exactly the shapes `CollisionChecker` reports (`contactObstacles`). The plan drag uses the same function after the
existing wall snap (furniture and groups only; a selection with walls or rooms keeps the old snap) and draws the touched
faces as guides. Limit: obstacles are built once per drag, so a piece an agent moves during the drag counts from the next
drag.

Round footprints and standing on furniture: a piece whose visible upright cylinder fills its whole size (round tables, trays, pots, stools; `FurnitureResolver.isRound`) collides and stops as a 48-corner polygon inscribed in its ellipse (`footprintPolygon`, `collisionOutline`) instead of its rectangle; a state that moves components keeps the rectangle. Resting (`RestingSurface`, `RestingField`, `RestingDrag` in `Sources/RoomsmithCore/Geometry/RestingSurface.swift`): the tops of all components of the other furniture on the level are surfaces; a single loose piece dragged in the plan or in 3D (not groups, not selections of several), a piece dropped from the standard catalog or the library, and a piece dropped in 3D over a table (the pointer ray meets the top first, `RestingSurface.rayHit`) stands at the top of its carrier, the surface that holds its whole footprint (+/- 2 mm), stored as its ordinary `position.z`, no new field. A surface counts as a carrier only if all of this holds: its top is between 150 mm (`minCarrierTop`: rugs and mats are no carriers) and 1500 mm (`maxCarrierTop`: the top of a tall cabinet is out of reach) above the level floor; its piece is shown in the 3D view (`Project.isInstanceShown`) and is no lamp; no component of any shown piece (also of the same one) reaches into the volume of the piece above the surface, and the piece ends under the ceiling. Carriers standing on the floor (underside of the instance at most 300 mm, `standingCarrierBottom`) win over hanging ones; within a class the highest wins, so a wall cabinet never beats the worktop below it. Pieces with `allowsOverlap` are never put onto furniture (no `RestingDrag`, `RestingSurface.z` keeps their height). The 3D drop uses the floor point when the hit surface does not qualify or the piece does not fit on it; the field is cached per drag and project revision. Dragged off, it returns to z = 0 only if it stood on a surface before (underside within 1 mm of a top); a piece lifted by hand keeps its height. ⌥ switches resting off like snapping. Its carrier never blocks the drag, and a piece standing on another (underside on a component top, outline inside it) is no `furnitureOverlap`, unless its outline overlaps another component of the carrier that reaches into its height (a lid above, a side panel). Pastes and drops from another project keep the height of the piece (transfers of one piece accept `restOnFurniture`, but no UI path sets it yet).

Momentum: the action of a scroll gesture is decided when the fingers touch down and stays the same through the
momentum phase; a click, key press, mode change or new touch ends a coast at once (`ScrollTracker`). The camera is
stored in the document (`setCamera`, no undo step) after 0.4 s without movement and at the end of clicks, pinches and
mode changes, never per frame. A camera-only change is view state: it raises the revision for subscribers but keeps a
clean document clean (no "Edited", no recovery file) and does not make an agent's `expectedRevision` stale
(`DocumentStore.contentRevision`). The camera reaches the file with the next save.

Framing (Aerial, Reset, Frame Selection) fits the eight corners of the content box into the view using the real
aspect ratio (`CameraRig.fitDistance`), so wide windows are filled and narrow ones never clip; a new project refits
once after the first layout. The ground plane follows the eye and always reaches past the far plane, and the shadow
range grows with the view distance.

All sensitivities are constants in `TrackpadTuning` (`Sources/Roomsmith/Scene/SceneTrackpad.swift`): rotations are
degrees per point of finger travel and zooms are logarithmic, so the feel does not depend on the camera distance.
`ROOMSMITH_SCENE_SELFTEST=1` prints the camera-math checks (`SCENE_SELFTEST` lines) without any input events.
Other 3D diagnostics: `ROOMSMITH_PERF=1` (sync timings); only under test mode: `ROOMSMITH_PERF_PROBE=1` (move one object 30 times and print
command-to-frame latency), `ROOMSMITH_SCENE_SELECT=1`, `ROOMSMITH_SCENE_SNAPSHOT=<png>` (live view),
`ROOMSMITH_SCENE_MEASURE=x1,y1,x2,y2` (test mode: Measure tool, then two clicks at these fractions of the 3D view counted from its top left, so a screenshot shows a finished measurement), `ROOMSMITH_SHOW_LAMPS=0|1` (test mode: sets the "Lamps" display option before the hooks run, e.g. for the offscreen render), `ROOMSMITH_SCENE_OFFSCREEN=<png>` (offscreen render; with `ROOMSMITH_SCENE_OPEN=turn|tilt[:progress]` every door and window that can open is drawn in that pose, progress 0...1, default 1, e.g. `turn:0.33`). With `ROOMSMITH_BENCHMARK=1` the app prints one
`ROOMSMITH_SCENE entities=… buildMs=… fps=…` line after the first scene build (`fps=n/a` while the window is hidden or
covered) and, a few seconds later, one `ROOMSMITH_RENDER pieces=… medianMs=… p95Ms=… fps=…` line with the offscreen
frame time at 1920 x 1080; `ROOMSMITH_RENDER_BENCH=1` prints that line for the project opened with `ROOMSMITH_OPEN`.
`ROOMSMITH_OFFSCREEN_BENCH=1` (test mode) compares fresh offscreen renders with a kept `OffscreenSceneSession` for 8 camera
moves at 960 x 1080 and prints `ROOMSMITH_OFFSCREEN pieces=… freshMedianMs=… keptMedianMs=… keptMaxMs=… maxChannelDiff=…`;
`ROOMSMITH_PRESENTER_3D=<png>` (test mode) writes each presenter 3D pane picture, see `docs/PRESENTER.md`.

## Panels and layout

* Visibility is view state, stored with `@AppStorage(..., store: AppDefaults.store)` (keys in `ViewKey` and `EditorLayoutKey`): sidebar, inspector, status bar, layout (plan, 3D, both), arrangement, divider fraction, 3D window detached, 3D controls (`AppModel.showSceneControls`, persisted; View > Hide 3D Controls hides the floating camera and display bars, the HUD stays). The 3D display options (`showCeilings`, `showLamps`, `onlyActiveLevel`, `wallOpacity`) and the sidebar tab are `@Observable` `AppModel` properties persisted in `AppDefaults.store` (`ViewKey`; the old `scene.*` standard-defaults values are migrated once), so SceneView, the offscreen render and the agent view tools read the same state; the plan editor takes viewport requests from `AppModel.planViewRequest` and reports its viewport to `AppModel.planViewport`; `AppViewBridge` (`Agent/`) implements the core's `AgentViewBridge` for `view.*`, `camera.preset` and `render.scene_image`. Under `ROOMSMITH_TEST_MODE` `AppDefaults.store` is a separate suite cleared at launch, so checks never touch the real settings.
* View menu (`ViewLayoutCommands`): Sidebar Control-Command-S, Inspector Option-Command-I, Status Bar Command-/, plan and 3D toggles (the last visible pane cannot be hidden), layouts Command-1/2/3, arrangement, separate 3D window Option-Command-3, Present Option-Command-P (a sheet of the main window, so it works with the toolbar item removed or the toolbar hidden), Agents Option-Command-A. Entries that do not apply are disabled. System items Show/Hide Toolbar and Customize Toolbar… come from `.toolbar(id:)`; arrangement, detach and agents are hidden by default there (they are in the menu).
* Toolbar: icons with `.help`, one principal item (tool segment; Select and Hand come first, the Hand tool is view-only). Do not put pickers or menus into the split view detail column (HSplitView inside NavigationSplitView with `.inspector` crashes, minimum widths grow); bars over the canvas are `.overlay`s. No overflow at 1000 pt with the default items (checked).
* Divider (`EditorSplit`): `@GestureState` drag, fraction written on end, double-click resets to 50 %.
* Detached 3D window: remembered with `detached` and an AppKit frame autosave (not under test mode); `restorationBehavior(.disabled)` plus `defaultLaunchBehavior(.suppressed)`, `ContentView` reopens it at launch. Closing windows while quitting does not clear `detached` (`AppDefaults.isTerminating`).
* Glass: `glassPanel(in:interactive:)` and `GlassGroup` (`App/Glass.swift`) use `glassEffect` on macOS 26 with a material fallback.
* Export: File > Export has plan, OBJ, 3D view as image (1920x1080 or 3840x2160) and Reports… (`ReportsSheet`: room report, bill of materials, clearance check as CSV or Markdown). `ExportActions.destination` shows the save panel; under test mode every export (plan PDF/SVG/PNG, OBJ, 3D image, reports) skips the dialog, uses the default options and writes to `ROOMSMITH_EXPORT_DIR` (file name sanitized). File > Import Background Image… stores the image (scale 1 mm per pixel) and switches to the Calibrate tool.
* Check hooks (test mode only, `App/TestHooks.swift`): `ROOMSMITH_HIDE`, `ROOMSMITH_LIBRARY_COLLAPSE`, `ROOMSMITH_SNAPSHOT_SHEET=photo|preview`, `ROOMSMITH_SIDEBAR_TAB=levels|objects|catalog`, `ROOMSMITH_APPEARANCE`, `ROOMSMITH_WINDOW_SIZE`, `ROOMSMITH_SHOW_PRESENTER`, `ROOMSMITH_SNAPSHOT_PANE=inspector,agent,presenter` (with `ROOMSMITH_SNAPSHOT`: also draws those panels offscreen as `<path>-pane-<name>.png`), `ROOMSMITH_SNAPSHOT=<path>` with `ROOMSMITH_SNAPSHOT_AFTER=<seconds>` (the app writes its own windows as PNG and quits; no screen-recording permission needed; the selected toolbar segment is drawn as a plain pill). Together with `ROOMSMITH_SNAPSHOT`, `ROOMSMITH_SNAPSHOT_SETTINGS=general|appearance|walk` also draws the Settings view on that tab offscreen (`<path>-settings-<tab>.png`) `ROOMSMITH_SNAPSHOT_SHEET=photo` draws the empty "Furniture from photos" sheet (`<path>-sheet-photo.png`) and `ROOMSMITH_SNAPSHOT_SHEET=preview` the library preview sheet of the first My Furniture entry (`<path>-sheet-preview.png`, 3D area empty offscreen); both are verified only through these pictures, not by clicking. `ROOMSMITH_SELECT=first|<name>` selects the first object of the active level (furniture preferred) or the first one whose title contains the name, so the inspector shows in a picture; the offscreen pictures of the sheet and Settings have no inspector.

## Screenshots and GIFs

Record the app with the macOS screen recorder, then convert with `scripts/gif.sh recording.mov docs/images/demo.gif 15 960`.

The pictures in `docs/images` come from the demo project (`scripts/make-demo.py`, which builds
`Examples/Demo Apartment.roomsmith` through the agent API):

- 3D pictures and GIFs: `python3 scripts/make-media.py <app>/Contents/Helpers/roomsmith-mcp docs/images` against a
  running test instance (`open -g -j -n` with `ROOMSMITH_TEST_MODE=1` and its own `ROOMSMITH_SOCKET` and
  `ROOMSMITH_SUPPORT_DIR`). It rebuilds the demo, refines it (styled doors and windows, material presets, lamps),
  saves the refined project and renders `hero-aerial`, `interior`, `walls-transparent`, `evening`, `night`,
  `doors-windows`, the `gallery-*` stills, `plan-dimensions`, `plan-furnished`, `prompt-kit-furniture`, `orbit.gif`,
  `walkthrough.gif`, `ai-build.gif`, `day-to-night.gif`, `lamps.gif`, `doors-states.gif`, `materials.gif` and
  `camera-modes.gif` with `render.scene_image`, `render.plan_image` and a `camera` per frame (the 3D ruler is a live
  overlay and has no offscreen picture);
  `scripts/gif.sh <frames-dir> <out.gif>` builds the GIFs (`GIF_COLORS`, `GIF_DITHER` keep textured floors small).
  `--only name,...` renders a subset, `--keep` keeps the work folder.
- Plan: File > Export > Plan as PDF or SVG (or the agent tool `export.plan`), converted to PNG.
- Window pictures: `scripts/make-windows.sh <Roomsmith.app> <refined project> <second project> <out-dir>` writes
  `app-light`, `app-dark`, `library`, `workspace`, `settings-walk` and `photo-sheet`. Each one is a hidden test-mode
  launch (`open -g -j -n`, so no window comes to the front) with `ROOMSMITH_SNAPSHOT` and the hooks listed under Check
  hooks. Open the refined project that `make-media.py --keep` saved. The offscreen window picture draws neither the
  inspector pane nor the presenter sheet, so those two have no picture. The catalog thumbnails stay empty offscreen
  too; keep the `library` and `workspace` pictures that were taken from a live window unless that changes.
- The video pictures take their frames from the app renderer; the GIF size is steered by `GIF_COLORS` and the width,
  not by the frame rate (`gif.sh` fps is the playback rate). `gif.sh` strips metadata (`-map_metadata -1`).

## Contributing

Keep changes small and focused, run `scripts/check.sh` before opening a pull request, and describe what you tested.
