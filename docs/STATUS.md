# Status

Overall: **feature complete, pre-release, not published.** All work packages below exist in code; README with images and GIFs, performance numbers (`docs/PERFORMANCE.md`) and the `docs/` layout are in place; open before the first release are the items in [ROADMAP.md](ROADMAP.md) under "Open before the first release". Evidence column: the file(s) in the repo that implement the package. Items marked "to verify" were not confirmed from code alone.

## Work packages

| Package | Status | Evidence |
|---|---|---|
| Data model, millimetre units (`Int64`) | done | `Sources/RoomsmithCore/Model/Entities.swift`, `Units.swift` |
| Geometry (snap, collision incl. open doors as carcass plus door slabs, wall outlines, rooms, dimension chains) | done | `Sources/RoomsmithCore/Geometry/` (`Snap.swift`, `Collision.swift`, `MoveContact.swift`, `WallOutline.swift`, `RoomFinder.swift`, `DimensionChains.swift`) |
| Meshes, triangulation | done | `Geometry/Meshes.swift`, `Triangulate.swift`; tests in `MeshExportTests.swift` |
| Markdown persistence, `.roomsmith/` folder format, schema migration | done | `Persistence/ProjectPackage.swift`, `RoomsmithMarkdown+Encode.swift`, `RoomsmithMarkdown+Decode.swift`, `ProjectMigration.swift`; format in [FILE_FORMAT.md](FILE_FORMAT.md) |
| Command engine, undo/redo, revisions | done | `Commands/Edits*.swift`, `Validator.swift`, `ChangeSet.swift`, `DocumentStore.swift` |
| Document store, autosave, backups | done | `Commands/DocumentStore.swift`, `Sources/Roomsmith/App/Autosave.swift`, `ProjectPackage.listBackups` (backup rotation keeps ten, see `PersistenceTests.swift`) |
| 2D plan editor | done | `Sources/Roomsmith/Plan/` (`PlanCanvas.swift`, `PlanTools.swift`, `PlanInteraction.swift`) |
| 3D view (RealityKit): orbit, free flight, first person, top, aerial, picking, gizmo, drop, saved views, FOV, wall opacity | done (manual check of the full interaction set: to verify) | `Sources/Roomsmith/Scene/` (`SceneCamera.swift`, `ScenePicking.swift`, `Gizmo.swift`, `SceneDrop.swift`, `SavedViewsPopover.swift`), wall opacity in `App/AppModel.swift` |
| Furniture builder, catalog, products, USDZ import | done | `Sources/RoomsmithCore/Catalog/`, `Furniture/`, `Sources/Roomsmith/Panels/FurnitureBuilderView.swift`, `Builder*.swift`, `Import/USDZImport.swift` (no automated test of the USDZ import: to verify) |
| Duplicate furniture designs: identical designs are reused on create/paste, the project list shows each name once, remove-unused command, `furniture.replace_definition` | done (swap has no UI yet, see PARITY C18; hosted app tests made non-activating: to verify by one run) | `Furniture/FurnitureDedup.swift`, `Commands/EditsDefinitionCleanup.swift`, `Furniture/FurnitureTransfer.swift`, `Agent/ToolsFurniture.swift`, `Sources/Roomsmith/Panels/SidebarCatalog.swift`, `CatalogActions.swift`; tests `DefinitionCleanupTests.swift`, `DefinitionCleanupToolTests.swift` |
| Groups, configurations, states, animation | done | `Commands/EditsObjects.swift`, `Catalog/ModularSofa.swift`, `Sources/Roomsmith/Scene/SceneAnimation.swift` |
| Agent IPC, MCP server, audit log | done | `Sources/RoomsmithIPC/` (`AgentSocketServer.swift`, `MCPBridge.swift`), `Sources/roomsmith-mcp/main.swift`, `Sources/RoomsmithCore/Agent/AuditLog.swift`; **114 tools** (see below) |
| Exports: SVG and PDF to scale, PNG, scene image, OBJ | done | `Export/PlanExport.swift`, `PlanFit.swift`, `PlanRaster.swift`, `SceneExport.swift`, `Sources/Roomsmith/Scene/SceneSnapshot.swift`, `Sources/Roomsmith/Agent/AppViewBridge.swift` |
| Reports (bill of materials, rooms, clearances) | done | `Sources/RoomsmithCore/Reports/`, `Sources/Roomsmith/Panels/ReportsSheet.swift` |
| Presenter mode (AirPlay route picker, second display) | done (live check on an AirPlay device: to verify) | `Sources/RoomsmithCore/Presenter/` (HLS), `Sources/Roomsmith/Presenter/PresenterViews.swift`, `PresenterWindowController.swift`; design in `docs/PRESENTER.md` |
| Performance benchmark | done | `Benchmark/BenchmarkProject.swift`, `Tests/RoomsmithCoreTests/BenchmarkTests.swift`, `scripts/benchmark.sh`, numbers in [PERFORMANCE.md](PERFORMANCE.md) |
| App bundle, release scripts | done | `scripts/bundle.sh`, `deploy.sh`, `release.sh`, `status.sh`, `icon.swift`, `Resources/Info.plist` |
| README, images, GIFs | done | `README.md`, `docs/images/`, `scripts/make-demo.py`, `scripts/gif.sh` |
| Measure tool in 3D and greyed-out plan tools in the 3D-only layout (two clicks on surfaces give distance and dx/dy/dz with a line and label that follow the camera; Select, Hand and Measure stay enabled in 3D, the other tools are greyed; app state, not in the document) | done in code (logic and hosted tests green; looked at in screenshots) | `Sources/RoomsmithCore/Interaction/Measure3D.swift`, `Sources/Roomsmith/Scene/SceneRenderer+Measure.swift`, `App/AppModel.swift` (`EditorTool.isAvailable`), `App/ContentView.swift` (`ToolPicker`); tests `Measure3DTests.swift`, `Tests/RoomsmithAppTests/MeasureTool3DTests.swift` |
| Hand tool (view-only mode next to Select: key H, V or Esc back, Space held = temporary hand; plan pans, 3D orbits, nothing is selected or edited; app state, not in the document) | done in code (policy tested in the core; the plan, 3D, cursor and key behaviour are not yet used by hand: to verify) | `Sources/RoomsmithCore/Interaction/HandMode.swift`, `Sources/Roomsmith/App/AppModel.swift` (`EditorTool.hand`), `Plan/PlanInteraction.swift`, `PlanCanvas.swift`, `Scene/SceneRenderer+Interaction.swift`, `SceneView.swift`, `App/EscapeClearsSelection.swift`; tests `HandModeTests.swift`, `Tests/RoomsmithAppTests/HandToolTests.swift` |
| Multi-project workspace (tabs, split, compare, drag and drop, move or copy objects between projects) | done (UI by hand: to verify; the offscreen pictures cover compare) | `Sources/Roomsmith/App/Workspace.swift`, `WorkspaceViews.swift`, `Sources/RoomsmithCore/Furniture/FurnitureTransfer.swift`, `Agent/ToolsWorkspace.swift`; tests `FurnitureTransferTests.swift`, `ToolsWorkspaceTests.swift` |
| Lighting (sun, sky, moods, exposure, lamps in furniture designs, lamps on or off per piece, "Lamps" 3D display option hides lamp furniture, i.e. designs with lights or category Lighting / lamp tag or name, but keeps its light; hidden lamps do not block walking or 3D dragging) | done (see Known limits) | `Sources/RoomsmithCore/Model/Lighting.swift`, `Lighting/SunPosition.swift`, `LightRig.swift`, `Commands/EditsLight.swift`, `Agent/ToolsLight.swift`, `Sources/Roomsmith/Scene/SceneEnvironment.swift`, `SceneRenderer+Light.swift`, `Panels/LightPanel.swift`, `InspectorLight.swift`; tests `LightTests.swift` |
| Walk mode (1:1 point of view, collisions, Space held walks through, doors, E switches furniture states, measuring, settings) | done (view state, not in the document; Space pass-through: tests green; not tried live) | `Sources/RoomsmithCore/Walk/` (`WalkSettings.swift`, `WalkMotion.swift`, `WalkCollider.swift`, `WalkMeasure.swift`, `WalkFurnitureState.swift`), `Agent/ToolsWalk.swift`, `Sources/Roomsmith/Scene/WalkController.swift`, `WalkSettingsPopover.swift`, `WalkSettingsStore.swift`, `Agent/AppWalkBridge.swift`; tests `WalkTests.swift` |
| Round footprints and standing on furniture (circle collision, resting on table tops, Option off) | done in code (tests green; to verify live) | `Geometry/RestingSurface.swift`, `FurnitureResolver.swift`, `Collision.swift`, `MoveContact.swift`; tests `RestingTests.swift` |
| Opening details (style, handle, frame width, mullions, glass) | done | `Geometry/OpeningDetail.swift`, `Agent/ToolsScene.swift`; tests `OpeningMaterialDetailTests.swift` |
| Material presets and procedural patterns | done | `Geometry/MaterialPresets.swift`, `ProceduralTexture.swift`, `Agent/ToolsMaterial.swift`, `Sources/Roomsmith/Panels/MaterialEditor.swift`, `Scene/SceneMaterials.swift`; tests `OpeningMaterialDetailTests.swift` |
| Furniture library (separate from the project and the catalog; sections, search, photos, thumbnails, drag token) | done | `Sources/RoomsmithCore/Library/` (`LibraryStore.swift`, `LibraryEntry.swift`, `LibraryContent.swift`), `Agent/ToolsLibrary.swift`, `Sources/Roomsmith/Library/`; tests `LibraryTests.swift` |
| Furniture from photos (Vision, approximation over 5 templates, improve an existing entry) | done (approximation, see Known limits; the photo sheet is checked by snapshot only) | `Sources/RoomsmithCore/Library/FromPhoto/`, `Agent/ToolsLibraryPhoto.swift`, `Sources/Roomsmith/Library/FromPhoto/` (`VisionFurnitureProvider.swift`, `PhotoToFurnitureSheet.swift`); tests `FromPhotoTests.swift` |
| Accessibility and error messages (keyboard and VoiceOver actions for library tiles, tabs, pane header, builder states; labels for plan, 3D view and icon buttons; invalid-input symbol and hint; readable error texts via `userMessage(for:)`) | done in code (message mapping and scene summary are tested; the keyboard and VoiceOver behaviour is not yet checked with VoiceOver or by hand: to verify) | `Sources/RoomsmithCore/Commands/UserMessage.swift`, `Sources/Roomsmith/Library/LibraryTileView.swift`, `ImageThumbnail.swift`, `App/WorkspaceViews.swift`, `Panels/Fields.swift`; tests `UserMessageTests.swift` |
| Last session and Open Recent (tabs, active tab and split reopen on launch; File > Open Recent with Clear Menu; missing files are skipped with a status message; recovered unsaved changes merge into the tab of the same file) | done (core tested; the menu and the restore are checked by an offscreen picture, not by clicking) | `Sources/RoomsmithCore/Persistence/SessionState.swift` (`SessionState`, `RecentProjects`), `Sources/Roomsmith/App/Workspace.swift` (session and recent), `AppLaunch.swift`, `RoomsmithApp.swift`, `AppDefaults.swift`; tests `SessionStateTests.swift` |
| Test hooks (`ROOMSMITH_TEST_MODE=1`, snapshot and launch variables) | done | `Sources/Roomsmith/App/TestHooks.swift`, `AppLaunch.swift`; variables in [DEVELOPMENT.md](DEVELOPMENT.md) |

### Agent tools

120 tools in 18 families: `app` 5, `project` 7, `scene` 17, `geometry` 14, `catalog` 7, `furniture` 21, `background` 3, `material` 4, `camera` 5, `view` 2, `render` 2, `history` 2, `export` 2, `report` 3, `walk` 4, `light` 5, `workspace` 5, `library` 12 (count from `docs/PARITY.md`). Checks: `ToolTests.swift` (`exposesAll120ToolsInFamilies`), the `### ` headings of [MCP_API.md](MCP_API.md), and the tool name literals in `Sources/RoomsmithCore/Agent/Tools*.swift` and `ToolRegistry.swift`.

## Tests

- 1086 `@Test` functions in `Tests/RoomsmithCoreTests/` (55 files; count by `grep -rE '^\s*@Test' Tests`) plus the app tests in `Tests/RoomsmithAppTests/`. Delete/Backspace deletes the unlocked selected furniture in the plan, the 3D view (not in first person) and on other controls (not in text fields). Test targets: `RoomsmithCoreTests` and `RoomsmithAppTests` (hosted drag, drop, Esc, Delete-key and mesh-tint checks of `Sources/Roomsmith`; needs a GUI session, about 20 s); the rest of the app side has no automated tests.
- Last full run green with 1100 core tests in 140 suites plus 56 app tests in 14 suites (run by `scripts/check.sh`); the number is counted again before the release.
- Acceptance rows and their tests: [TEST_MATRIX.md](TEST_MATRIX.md).

## Next steps

1. Capability gaps between the app and the agent API: `docs/PARITY.md` (120 rows: 118 at parity, one UI gap C18, X7 is by design covered by X5/X6).
2. Open milestones and the backlog: [ROADMAP.md](ROADMAP.md).
3. Run `scripts/check.sh` (build, tests, Info.plist lint, forbidden-files check); it must end with `RESULT: GREEN` before a package counts as done.

## Known limits

- The sidebar library shows only your own furniture plus 5 built-in examples (`BuiltinCatalog.exampleKeys`); the rest of the built-in catalog is reachable only through agent tools. The "New" badge for agent additions (objects and library entries) lives in memory only and is not seen in a running app yet: the SwiftUI side is verified by build, the logic by tests.
- The Light panel sliders (time, day, north, latitude, exposure) preview live in the 3D view while dragging (`AppModel.lightPreview`, not saved, not undoable) and commit one undoable command on release. The offscreen renderer ignores the preview. Not yet tried by hand in the running app; lamp sliders in the inspector still commit only on release.
- Lamp brightness is estimated, not calibrated: `lumens` is mapped to a RealityKit intensity with one gain factor (`lampGain` in `Scene/SceneRenderer+Light.swift`) chosen by eye.
- The "Lamps" display option only affects the 3D view (picture, picking, walk collision); the plan still draws lamp furniture. The click on the toggle itself was not tried, only the offscreen pictures with `ROOMSMITH_SHOW_LAMPS=0|1`.
- Lamps cast no shadows (RealityKit point lights); light passes through walls and furniture. Only the sun casts shadows.
- There is no physical sky: the sky is a small generated environment image per mood, and sun position and sky are not tied together. The scene is lit by the bright sky image in light and dark appearance; dark appearance only darkens the background and ground.
- OBJ and USDZ export contain neither the lamps nor the sun.
- Photo to furniture is an approximation over the 5 builder templates (`cabinet`, `table`, `shelf`, `sofa`, `box`), not a 3D reconstruction; a photo cannot tell real sizes, so at least one dimension must be given and the others are estimated.
- A library entry without a builder recipe (one saved from placed furniture) cannot be improved from a photo.
- A failed improve can leave orphaned assets in the library folder.
- The photo sheet is verified only through the offscreen snapshot (`ROOMSMITH_SNAPSHOT_SHEET=photo`), not by clicking.
- The selection colour in the active window is unverified: hidden launches never make the window key.
- The inspector stays empty in the offscreen snapshot, so pictures cannot show it.
- `render.scene_image` and the presenter draw doors and windows in the pose the live view shows (closed when there is no live view); the open state is view state and is lost when the project is closed.
- Windows open as turn or tilt (F10): hinges are part of the frame, handles are on the sash, and sizes below the sash minimum stay fixed. Sliding doors never open. Sash and glass bars are one mesh per sash; there is no seal or sound/heat model.
- Only balcony doors with a sill of at most 100 mm can be walked through when turned open (default, not measured); every other window stays a wall for the walking body.
- The opening animation takes a fixed time; the pose is verified through still pictures and mesh tests, not by watching the animation in the running app.
- The library preview sheet uses an interactive scene view on a scratch project; dragging inside it changes only the scratch copy.
- Tile drag, double click and the category drop are verified only through code and pictures, not by clicking.
- Furniture options: a group configuration does not store the option selection; without a state pose the footprint and collision box stay the nominal one, whatever options hide.
- Z arrow of the gizmo: drawn onto tops below and undersides above the piece and onto the floor (`Geometry/VerticalContact.swift`; tests green, to verify live). Free dragging keeps the carrier rule below.
- Resting: carrier rule tightened (150 to 1500 mm tops, shown and no lamp, free space above, standing before hanging, `allowsOverlap` never rests, 3D drop falls back to the floor on a surface that does not fit). Space keyUp now always clears `pressedKeys`; entering First person clears a held temporary Hand. Test counts: green (1070 core, 49 app).
