# Roadmap

Milestones are vertical slices. A milestone is done only when its features were checked manually, by automated tests, and after save and reopen where applicable. Status column: `done` = implemented and covered by evidence in the repo (file named), `open` = not done, `to verify` = not confirmed from code alone. Current state: [STATUS.md](STATUS.md). Acceptance tests: [TEST_MATRIX.md](TEST_MATRIX.md).

| Milestone | Content | Depends on | Acceptance | Status |
|---|---|---|---|---|
| M0 Bootstrap | Repository, rules and agent docs, package layout, `scripts/check.sh`, app shell that builds and starts, smoke test, requirements and feature catalogue | none | App launches; `scripts/check.sh` GREEN | done: `scripts/check.sh`, `Package.swift`, `Sources/Roomsmith/App/RoomsmithApp.swift` |
| M1 Exact data and 2D planning | Document model in mm, units, command engine with undo/redo and revisions, walls, rooms, dimension lines, snapping, 2D editor, save and open in `.roomsmith` | M0 | G01, G02, G03 | done: `Commands/Edits*.swift`, `DocumentStore.swift`, `Sources/Roomsmith/Plan/`; G01, G03 covered, G02 partial |
| M2 Live 3D, camera and gizmos | Same document in RealityKit, incremental updates, picking, orbit/top/first-person cameras, X/Y/Z gizmo, rotation, numeric entry, snapping and collision warning | M1 | E01, E02, E03 | done (interaction check by hand: to verify): `Sources/Roomsmith/Scene/`; E01, E02 partial, E03 manual |
| M3 Furniture and catalog | Parametric furniture builder, materials, USDZ import, library, product information and links, search and filters | M2 | F01 | done: `Sources/RoomsmithCore/Catalog/`, `Panels/FurnitureBuilderView.swift`, `Import/USDZImport.swift`; F01 covered |
| M4 Groups, states, animation | Groups with reparenting, configurations (modular sofa 1/2/3), states (fold-out bed), transitions, undo and save roundtrips | M3 | S01, S02 | done: `Commands/EditsObjects.swift`, `Scene/SceneAnimation.swift`; S01 covered, S02 partial |
| M5 Live agent control | Socket server in the app, token auth, write lock and status indicator, audit log, conflict handling, change stream, `roomsmith-mcp`, tool API, agent handbook and example prompts | M1 (M2 to M4 for full tool set) | A01, A02, A03 | done: `Sources/RoomsmithIPC/`, `Sources/roomsmith-mcp/`, `Agent/Tools*.swift` (114 tools); A02, A03 covered, A01 partial |
| M6 Feature coverage and exchange | Doors and windows, levels, background image calibration, alignment tools, saved cameras, further planning functions, exports (SVG, PDF to scale, image, OBJ); close the feature matrix | M1 to M4 | Matrix rows with passing tests | done: `docs/PARITY.md` (120 of 120 rows at parity); exports in `Export/` |
| M7 Quality and performance | Benchmarks (many walls plus 1,000 objects), profiling, regression tests, UI refinement, accessibility, installable `.app` build, crash-safe saving checks, README with images and GIFs | M1 to M6 | P01, D01 | partly done: installable `.app` (`scripts/bundle.sh`) and crash-safe saving (D01 covered) done; README with images and GIFs done; performance numbers incl. 3D frame times in `docs/PERFORMANCE.md` (P01); accessibility: to verify |
| M8 Beyond the spec | Own research into user workflows; prioritised feature list in ROADMAP; implement, test and polish item by item until no meaningful extension is left | M7 | Each item: manual check, tests, docs | in progress: see backlog below |

Priority principle: a precise core with real interactive 3D manipulation and working live agent control comes before photorealism or a large starter library. Geometry correctness is never traded for features.

### M8 delivered (beyond the original waves)

Status: implemented; evidence per package in [STATUS.md](STATUS.md), limits under "Known limits" there.

- Multi-project workspace: tabs, split, compare, drag and drop, move or copy objects between projects (`workspace.*`).
- Lighting: sun by date, time, latitude and north angle; moods; exposure; lamps in furniture designs; lamps on or off per piece (`light.*`). Wave 3 still lists "lights and sun study"; the delivered part has no lamp shadows and no physical sky.
- Walk mode: 1:1 point of view with collisions, doors and measuring (`walk.*`).
- Opening details (style, handle, frame width, mullions, glass), material presets and procedural patterns (wave 3 still lists "tiling patterns", which means patterns on surfaces and is not covered by this).
- Furniture library separate from projects, and furniture from photos (Vision, five templates).

### Open before the first release

- Extensions: print layout with title block, USDZ export, RoomPlan scan import.

### M8 backlog (prioritised)

Wave 1 (small, high value; builds on existing code):
1. Plan check / validator report in the UI (open rooms, overlapping walls, loose openings). Partly done: clearance/overlap checks in `Reports/ClearanceCheck.swift`, `Agent/ToolsReports.swift`; open rooms and loose openings: to verify.
2. Bill of materials / shopping list with prices (CSV/PDF) from product fields. Done: `Reports/BillOfMaterials.swift`, `ReportFormat.swift`, `Panels/ReportsSheet.swift` (PDF output: to verify).
3. Print layout with title block, scale bar and north arrow; compass direction in the project. Open (SVG/PDF export to scale with scale bar exists in `Export/PlanExport.swift`; title block and printing are open).
4. Room schedule and area report, incl. living area (WoFlV/DIN 277 factors once sloped ceilings exist). Room report done: `Reports/RoomReport.swift`; living-area factors open.
5. Automatic dimension chains (outer/inner) that stay live. Done: `Geometry/DimensionChains.swift`, `Commands/EditsDimensionChain.swift`.
6. USDZ export of the scene for AR Quick Look (1:1 scale). Open.
7. Trackpad parity everywhere: pinch zoom to pointer, two-finger pan/orbit, rotate gesture, smart zoom. Done for plan and 3D: `Geometry/PlanGesture.swift`, `Scene/SceneTrackpad.swift` (smart zoom: to verify).

Wave 2: clearance/walkway and accessibility checks (150 cm turning circle), quantity take-off (paint, flooring, tiles), skirting and trim, layers, text notes and room labels, measure tool in 3D, array/mirror/align to wall.

Wave 3: stairs, sloped ceilings and knee walls, electrical symbols, lights and sun study, DXF export/underlay, tiling patterns, plan variants and renovation phases.

Wave 4: section and elevation views, walkthrough video and 360 render, render quality (shadows, AO), localization and imperial units, manufacturer catalogs, RoomPlan scan import.

M8 cross-cutting goals: per-element show/hide for all panels and tools; full UI ↔ agent parity table in
`docs/PARITY.md` (done); macOS 27 Liquid Glass look; usability review pass (discoverability, keyboard, empty states).

### M8 presenter mode (high priority)
Status: done (HLS stream, AirPlay route picker, second-window fallback): `Sources/RoomsmithCore/Presenter/`, `Sources/Roomsmith/Presenter/`; live check on an AirPlay device: to verify.

AirPlay presenter: render plan / 3D / both offscreen at 1080p (4K option), stream to Apple TV as video via an AirPlay route picker in the toolbar. Follows the editor live (camera, selection highlight optional), hides editor chrome, shows a pointer highlight. Fallback: presenter window on any second display (HDMI, Sidecar, AirPlay display). Research and design in docs/PRESENTER.md.
