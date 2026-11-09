# UI / Agent parity

Goal: every capability of Roomsmith can be used by hand in the app **and** by an AI agent through the MCP API
(`docs/MCP_API.md`, tools in `Sources/RoomsmithCore/Agent/`). This table is the working list; close the gaps in the
order given under "Gaps to close". Snapshot of the working tree; rows marked **wip** would point at code
that is visibly unfinished (none at the moment).

How to read it

- **UI**: `yes` + `file:line` of the entry point (menu, toolbar, inspector, gesture), `no` if the app cannot do it, `wip` if code exists but is not reachable or is a placeholder.
- **Agent**: tool name, or `no`. `n/a` = deliberately not offered (consent, pure human gesture, or nothing to do).
- **Gap**: `UI`, `Agent`, `both` or `-`. A proposal is given for each gap. Sizes S/M/L are in the gap lists below.
- Agent tools always act on the open project; reads (`scene.list_objects`, `project.get_scene_snapshot`, ...) have no UI row because the UI shows the same data directly.
- Paths are relative to `Sources/Roomsmith/`. Line numbers are of this snapshot and will drift.
- Rule for view state (layout, camera, plan zoom, wall transparency): the agent should be able to set and read it, because screenshots and exports depend on it. Such state is app state, not document state: no undo step and no "Edited" state; at most a revision bump for subscribers that never makes `expectedRevision` stale (like `camera.set_state`, see `DocumentStore.contentRevision`).

## 1. Project and files

| # | Capability | UI | Agent | Gap | Proposal |
|---|---|---|---|---|---|
| F1 | New project | yes `App/RoomsmithApp.swift:57` | `project.new` | - | done: `project.new {discard?}` (CONFLICT while dirty without `discard`; no dialog) |
| F2 | Open project | yes `App/RoomsmithApp.swift:58`, Finder open `:45` | `project.open` | - | done: `project.open {path, discard?}` |
| F3 | Save | yes `App/RoomsmithApp.swift:61` | `project.save` (only with an existing file) | - | - |
| F4 | Save as | yes `App/RoomsmithApp.swift:62` | `project.save_as` | - | done: `project.save_as {path, overwrite?}` (no `discard`: saving loses nothing) |
| F5 | Rename project | yes `Panels/InspectorView.swift:102` | `project.update_settings {name}` | - | done |
| F6 | Undo / redo | yes `App/RoomsmithApp.swift:65-68` | `history.undo`, `history.redo` | - | - |
| F7 | Discard-changes prompt, autosave recovery | yes `App/AppModel.swift:180`, `App/Autosave.swift:78` | n/a | - | Human dialogs; agent gets `project.open/new` with explicit `discard` |
| F8 | Allow agents to change project (write switch) | yes `Agent/AgentPanel.swift:23` | `app.get_capabilities` (read `writeEnabled`) | - | Switch stays human-only on purpose |
| F9 | Connect an agent (setup command, socket path, activity log) | yes `Agent/AgentPanel.swift:45-47` | n/a | - | - |
| F10 | Project state / overview (revision, dirty, levels, selection, counts) | yes `App/ContentView.swift:105` status bar, `Panels/InspectorView.swift:95` | `app.get_active_project`, `project.get_summary`, `project.get_scene_snapshot` | - | - |
| F11 | Atomic multi-step edit, dry run, optimistic locking, change feed | n/a | `app.batch`, `dryRun`, `expectedRevision`, `app.subscribe_changes`, `app.list_tools`, `app.get_capabilities` | - | Agent-only by nature |
| F12 | Several projects as tabs: new, open, switch, close | yes `App/WorkspaceViews.swift:19-22` (new tab), `:47,62` (close), `App/RoomsmithApp.swift:70-72`, `App/WorkspaceViews.swift:223-224` (next / previous) | `workspace.list`, `workspace.activate`, `workspace.open`, `workspace.close` | - | `workspace.close` without `discard` answers `CONFLICT` while the tab has unsaved changes |
| F13 | Compare two projects: split side by side or stacked, figures table | yes `App/WorkspaceViews.swift:226-237` (Projects menu), `:56-60` (tab context menu), `:141-181` (figures sheet) | `workspace.compare {projectA?, projectB?, show?, arrangement?}` | - | Without `show` it only returns the figures |

## 2. Selection and generic object edits

| # | Capability | UI | Agent | Gap | Proposal |
|---|---|---|---|---|---|
| S1 | Select (click, marquee, tree), select all / none | yes `Panels/EditCommands.swift:52,57`, `Plan/PlanInteraction.swift` | `scene.select_objects` | - | - |
| S2 | Frame selection (plan and 3D) | yes `Panels/EditCommands.swift:60`, `Panels/SidebarObjects.swift:224` | `camera.preset {preset: frame, ids?}` (3D); plan: `view.set {planFit}` | - | done |
| S3 | Delete | yes `Panels/EditCommands.swift:17`, `Plan/PlanInteraction.swift:530` | `scene.delete_objects` (levels, walls, rooms, openings, dimensions, backgrounds, furniture, groups) | - | See C13, V12 for kinds it cannot delete |
| S4 | Duplicate | yes `Panels/EditCommands.swift:24` | `scene.duplicate_objects` | - | - |
| S5 | Group / ungroup | yes `Panels/EditCommands.swift:29,32` | `scene.group_objects`, `scene.ungroup_objects` | - | - |
| S6 | Lock / unlock | yes `Panels/EditCommands.swift:37` | `scene.set_locked` | - | - |
| S7 | Hide / show | yes `Panels/EditCommands.swift:40` | `scene.set_visible` | - | - |
| S8 | Rotate 90 degrees / by angle | yes `Panels/EditCommands.swift:44,47`, `Panels/InspectorMulti.swift:38` | `scene.rotate_objects` | - | - |
| S9 | Move (drag, arrow-key nudge, numeric delta) | yes `Plan/PlanInteraction.swift:212,528`, `Panels/InspectorMulti.swift:30` | `scene.move_objects` | - | - |
| S10 | Align left / right / top / bottom | yes `Panels/InspectorMulti.swift:42-45,97` | `scene.align_objects` | - | done |
| S11 | Rename an object | yes `Panels/InspectorView.swift:37` | `scene.rename_object` | - | done |
| S12 | Apply material (walls both sides, room floor / ceiling, opening frame, furniture all / per component, reset) | yes `Panels/InspectorGeometry.swift:43-47,95-99,166`, `Panels/InspectorFurniture.swift:61-72` | `scene.set_material` | - | - |
| S13 | Collision warnings overlay | yes (setting `Panels/SettingsView.swift:31`, plan overlay) | `scene.check_collisions`, `geometry.measure_distance` | - | - |
| S14 | Hover highlight, status-bar cursor position, snap suspend with Option | yes `App/AppModel.swift` (`hoveredId`, `cursorPoint`, `snapSuspended`) | n/a | - | Transient pointer state, no agent use |
| S15 | Copy or move furniture to another open project (menu, drag from the objects list onto the other project's plan) | yes `App/WorkspaceViews.swift:239-250` (Projects > Copy / Move Selection to), `Panels/SidebarObjects.swift:197-206` (drag source), `Plan/PlanDrop.swift:124` (drop) | `scene.transfer_objects {targetProjectId, ids, move?}` | - | Furniture and groups only; a group id expands to its members |

## 3. Plan drawing tools

| # | Capability | UI | Agent | Gap | Proposal |
|---|---|---|---|---|---|
| P1 | Draw walls (click chain, typed length, close loop) | yes `Plan/PlanTools.swift:49-116` | `geometry.create_wall` | - | - |
| P2 | Draw room by outline | yes `Plan/PlanTools.swift:129-170` | `geometry.create_room` | - | - |
| P3 | Room from enclosed walls (double click) | yes `Plan/PlanTools.swift:174,373` | `geometry.create_room_from_walls` | - | done |
| P4 | Place door / window / opening (with hinge flip) | yes `Plan/PlanTools.swift:184-245` | `geometry.add_opening` | - | - |
| P5 | Dimension line create | yes `Plan/PlanTools.swift:247-262` | `geometry.create_dimension` | - | - |
| P6 | Dimension line edit (from, to, offset) | yes `Panels/InspectorGeometry.swift:198-202` | `geometry.update_dimension` | - | done |
| P6b | Dimension chain along a wall (start, opening edges, end, total) or through points | yes plan context menu "Add Dimension Chain" (`Plan/PlanContextMenu.swift`) | `geometry.dimension_chain` | - | done |
| P7 | Measure tool | yes, in the plan `Plan/PlanTools.swift:269` and in the 3D view `Scene/SceneRenderer+Measure.swift:47` (two clicks on surfaces; same distance text, shared `DistanceText`, plus dx/dy/dz) | `geometry.measure_distance` | - | The 3D measurement is UI-only (view state, nothing is saved), so it needs no tool of its own; agents read distances with `geometry.measure_distance` |
| P8 | Wall edit: ends, thickness, height, length, faces, lock | yes `Panels/InspectorGeometry.swift:20-66` | `geometry.update_wall` | - | - |
| P9 | Wall split | yes `Panels/InspectorGeometry.swift:52` | `geometry.split_wall` | - | - |
| P10 | Room edit: corners add / move / remove, floor / ceiling, show floor / ceiling | yes `Panels/InspectorGeometry.swift:91-134` | `geometry.update_room` | - | - |
| P11 | Opening edit (kind, offset, width, height, sill, mirror, inward, frame material) | yes `Panels/InspectorGeometry.swift:152-167,196-198` | `geometry.update_opening` | - | - |
| P19 | Opening look: style, handle, glass type, frame width, glazing bars (mullions) | yes `Panels/InspectorGeometry.swift:171-189` (the style list depends on door or window) | `geometry.add_opening`, `geometry.update_opening` (`style`, `handle`, `glass`, `frameWidthMm`, `mullionCols`, `mullionRows`) | - | `scene.get_object` outputs the same values as `frameWidth` / `glassType` |
| P12 | Select-tool handles (wall ends, room corners, dimension ends, rotate handle) | yes `Plan/PlanInteraction.swift:192,227` | same tools as P8, P10, S8 | - | - |
| P13 | Background image: add (import) | yes: `File > Import Background Image...` (`Panels/BackgroundImport.swift`) | yes `background.add` (path copied into `assets/`, `mmPerPixel` or two pixels + length) | - | Agent: `background.add {path, mmPerPixel}` or two pixels + length |
| P14 | Background image: show / hide, move, delete | yes: background section in the inspector (`Panels/InspectorBackground.swift`: visible, opacity, origin, delete) | `scene.set_visible`, `scene.move_objects`, `scene.delete_objects` accept background ids; `background.update` (opacity, visible, originMm, levelId) | - | Same commands on both sides |
| P15 | Background image: calibrate by two points + real length | yes: "Calibrate..." in the background inspector sets `EditorTool.calibrate` (`Plan/PlanTools.swift:298`) | yes `background.calibrate` (whole-pixel points, origin rounded to whole mm; Core `Project.calibrateBackground`) | - | The tool is reached from the inspector, not from the toolbar |
| P16 | Plan zoom, pan, fit (scroll, pinch, space-drag) | yes `Plan/PlanInteraction.swift:121-152`, `Plan/PlanCanvas.swift:195` | `view.set {planViewport, planFit}` | - | done |
| P17 | Current tool choice (toolbar) | yes `App/ContentView.swift:188` (in the 3D-only layout only Select, Hand and Measure are enabled; the plan tools are greyed with a hint, `EditorTool.isAvailable(in:)`) | n/a | - | Mouse mode; the agent edits directly |
| P18 | Drop furniture from library into plan | yes `Plan/PlanDrop.swift:93` | `catalog.insert_builtin`, `furniture.create_instance` | - | - |

## 4. Levels

| # | Capability | UI | Agent | Gap | Proposal |
|---|---|---|---|---|---|
| L1 | Add level | yes `Panels/SidebarLevels.swift:50` | `geometry.create_level` | - | - |
| L2 | Rename, elevation, height | yes `Panels/SidebarLevels.swift:73-85` | `geometry.update_level` | - | done |
| L3 | Show / hide level, lock level | yes `Panels/SidebarLevels.swift:16,21` | `scene.set_visible`, `scene.set_locked` with a level id | - | - |
| L4 | Delete level | yes `Panels/SidebarLevels.swift:35` | `scene.delete_objects` with a level id | - | - |
| L5 | Switch active level | yes `Panels/SidebarView.swift:38` | `view.set {activeLevelId}`; `scene.select_objects.levelId` | - | done |
| L6 | Reorder levels | no (order = elevation) | n/a | - | - |

## 5. Catalog, furniture, products

| # | Capability | UI | Agent | Gap | Proposal |
|---|---|---|---|---|---|
| C1 | Browse / search built-in catalog | partly: the sidebar shows and searches only the 5 Examples (`BuiltinCatalog.exampleKeys`, `Panels/SidebarCatalog.swift:21`); the full catalog is agent-only | `catalog.list_builtin` | - | - |
| C2 | Add built-in entry | yes `Panels/SidebarCatalog.swift:99`, `Panels/ObjectActions.swift:150` | `catalog.insert_builtin` | - | - |
| C3 | Modular sofa set | yes: context menu of the sofa tile in Examples (`Library/LibrarySectionsView.swift`, `ExamplesSection`) -> `Panels/ObjectActions.swift:162` | `catalog.insert_builtin` key `sofa.modular` | - | - |
| C4 | Add own design (My furniture) | yes `Panels/ObjectActions.swift:176` | `furniture.create_instance`, `furniture.list_definitions` | - | - |
| C5 | Furniture inspector: position, rotation, size, reset size, visible, lock, allow overlap, name | yes `Panels/InspectorFurniture.swift:25-48` ("Allow overlap", `inspector.allowsOverlap`) | `furniture.update_instance` (`allowsOverlap`), `furniture.create_instance` (`allowsOverlap`), `scene.set_locked` | - | `allowsOverlap` also shows in the `scene.list_objects` furniture rows |
| C6 | Switch state (animated in 3D) | yes `Panels/InspectorFurniture.swift:50` | `furniture.activate_state` | - | - |
| C7 | Per-component material / apply to all / reset | yes `Panels/InspectorFurniture.swift:61-72` | `furniture.update_instance.materials`, `scene.set_material` | - | - |
| C8 | Product: add / edit / link / unlink / search | yes `Panels/InspectorFurniture.swift:126-133,289` | `catalog.create_product`, `catalog.update_product`, `catalog.link_product` (null unlinks), `catalog.search_products` | - | - |
| C9 | Group inspector: move, rotate, lock | yes `Panels/InspectorGroup.swift:27-32,93` | `scene.move_objects`, `scene.rotate_objects`, `scene.set_locked` | - | - |
| C10 | Group configurations: save current, activate, overwrite, delete | yes `Panels/InspectorGroup.swift:51-74` | `furniture.save_configuration`, `furniture.activate_configuration`, `furniture.delete_configuration`, `furniture.list_configurations` | - | - |
| C11 | Configuration rename, duplicate | yes `Panels/InspectorGroup.swift:59,60,104,114` | `furniture.update_configuration` | - | done |
| C12 | Material library: create / edit materials (colour, roughness, finish, procedural pattern with second colour, size, angle, grout, clearcoat, specular) | yes: material editor sheet (`Panels/MaterialEditor.swift`), sidebar "Materials..." and "Edit..." | yes `material.create/update` | - | Same commands as `material.create/update`; the pattern preview tile is UI only |
| C13 | Delete a design (definition), product, saved camera, material | yes: catalog context menu (designs, products, materials; only unused entries), saved views popover (cameras) | `scene.delete_objects` (definition, product, camera, material; refused while referenced) | - | - |
| C14 | Import 3D model (USD / USDZ) as design + instance | yes `Panels/ExportCommands.swift:11`, `Import/USDZImport.swift:36` | `catalog.import_model {path, name?, place?: {position, levelId?}}` (needs a saved project package) | - | done |
| C15 | Material presets (paint, wallpaper, tiles, wood, fabric, leather, metal, glass, plastic) | yes `Panels/MaterialEditor.swift:145-155` (Preset menu in the material editor) | `material.apply_preset`, `material.list_presets` | - | done |
| C16 | Furniture options (colour, front, handle): pick one choice per group on a placed piece | yes `Panels/InspectorFurniture.swift:72-85` ("Options" section, `inspector.option.<group>`) | `furniture.set_options`, `furniture.create_instance.options`, `furniture.update_instance.options` | - | done |
| C17 | Remove unused designs of the project; the "In this project" list shows each design name once (rule: `Project.listedOwnDefinitions`) | yes `Panels/SidebarCatalog.swift:58,117` (list context menu and button), `Library/LibraryCommands.swift:13` (Edit menu), "Remove Unused Furniture…" with a count, one undo step | `furniture.prune_unused_definitions` (dry run by default), `furniture.delete_definitions`, `furniture.list_definitions {unused}` | - | done |
| C18 | Swap the model of placed pieces for another design (state, options and colours carry over by name) | no | `furniture.replace_definition` | UI | Inspector "Replace model" picker over the designs list; calls `Project.replaceDefinition` (M) |

## 5b. Library

| # | Capability | UI | Agent | Gap | Proposal |
|---|---|---|---|---|---|
| L7 | Create furniture from photos (template, proportions and colour from the photo plus known sizes, saved to the AI section) | yes: sheet `Library/FromPhoto/PhotoToFurnitureSheet.swift` via the button "Furniture from photos..." in the AI section (`Library/LibrarySectionsView.swift`) and the menu command `Library/FromPhoto/PhotoCommands.swift` | `library.create_from_photo {imagePath\|imagePaths\|imageBase64, dimensions, hint?, name?}` | - | Same pipeline (`RoomsmithCore/Library/FromPhoto/`); the sheet can open the furniture builder prefilled and saves with "Save to AI Library" |
| L8 | Improve an entry with a new photo (keeps hand edits, optional kept fields) | yes `Library/LibraryDetailView.swift` ("Improve with new photo...") | `library.create_from_photo {improveEntryId, keepFields?}` | - | The sheet shows the fields to keep as toggles |
| L9 | Save placed furniture or a design to the library (own or planned section) | yes: menu command Edit > "Save to My Furniture" and the context menus of the plan, the object list and the library (`Library/LibraryCommands.swift`); the old Add button is gone | `library.add_from_object {ids\|definitionId, section?, categoryId?}` | - | Standard pieces: copy to My Furniture via the tile menu (UI only, n/a for agents: `library.add_from_object` after `catalog.insert_builtin`) |
| L10 | List, search and open entries; edit name, description, section, status; update from the selection; delete | yes `Library/LibrarySectionsView.swift:29-60,92` (sections, tile pencil and "Edit…" in the menu), `Library/LibraryDetailView.swift:21-70` | `library.list`, `library.get`, `library.update`, `library.delete` | - | `library.update` with `fromObjectId` is the "Update from selection" button (`Library/LibraryDetailView.swift:63`) |
| L11 | Place an entry in the active project | yes `Library/LibrarySectionsView.swift:94,113` (tile context menu "Place on <level>", VoiceOver action, drag into plan or 3D; there is no Add button and a double click opens the preview, it does not place) | `library.place` | - | Undoable like any edit |
| L12 | Entry picture (thumbnail, cached at 384 px) | yes `Library/LibraryModel.swift:99` (pictures in the list and the details) | `library.thumbnail` | - | Inline MCP image or `path` |
| L13 | Own categories in My Furniture (create, rename, reorder, delete with target, collapse, drag a tile onto a header) | yes `Library/LibrarySectionsView.swift`, `Library/LibraryDialogSheet.swift` | `library.create_category`, `library.update_category`, `library.delete_category`; `categoryId` on `library.list/add_from_object/update` | - | `library.duplicate` is the agent side of the tile menu "Duplicate" |
| L14 | Large preview and rotatable model on double click; Edit design for builder pieces | yes `Library/LibraryPreviewSheet.swift`, `Library/LibraryDesignEditor.swift` | n/a | - | Edit design: agents use `furniture.*` on a placed piece and save it again |

## 6. Furniture builder (sheet)

| # | Capability | UI | Agent | Gap | Proposal |
|---|---|---|---|---|---|
| B1 | Open builder (new / edit design) | yes `Panels/SidebarCatalog.swift:98`, `Panels/InspectorFurniture.swift:47` | n/a (the tools below replace the sheet) | - | - |
| B2 | Generate from template + parameters | yes `Panels/FurnitureBuilderView.swift:60-87` | yes `furniture.create_from_template` (cabinet, table, shelf, sofa, box) | - | `furniture.create_from_template {template, name, size, shelves?, doors?, plinth?, legInset?, topThickness?, boards?, armWidth?, seatHeight?, material?}` |
| B3 | Create design, save, save and place | yes `Panels/FurnitureBuilderView.swift:160-163` | `furniture.create_definition` (+ `furniture.create_instance`) | - | - |
| B4 | Edit an existing design: add / remove / reshape components, shape, mesh asset, pivot, material, visible | yes `Panels/BuilderComponentsPane.swift:125-153` | yes `furniture.update_definition` (update/add/remove parts, keeps ids) | - | `furniture.update_definition {id, name?, category?, size?, tags?, updateComponents?, addComponents?, removeComponents?}` (part ids stay; instances with own size keep it) |
| B5 | States: add from current pose, delete, pose per component, default state, footprint override | yes `Panels/BuilderStatesPane.swift:40-140` | `furniture.define_state`, `furniture.delete_state` | - | done |
| B6 | Animation tracks between two states (duration, easing) | yes `Panels/BuilderStatesPane.swift:146-182` | `furniture.set_animation` | - | done |
| B7 | Preview state, top / front preview | yes `Panels/FurnitureBuilderView.swift:114` | n/a | - | Covered by `render.*` (X5) |
| B8 | Options: groups, choices, material / visibility per part, default choice | yes `Panels/BuilderOptionsPane.swift` (tab "Options") | `furniture.define_option_group`, `furniture.delete_option_group` | - | done |

## 7. View, camera, 3D

The 3D view (`Scene/SceneView.swift`, RealityKit) is wired to the camera controller, picking, gizmo, drop, animation and materials under `Scene/`.

| # | Capability | UI | Agent | Gap | Proposal |
|---|---|---|---|---|---|
| V1 | Layout Plan / 3D / Plan + 3D | yes `App/ContentView.swift:68`, `App/EditorLayout.swift:131-133` (`⌘1-3`) | `view.set {layout}`, `view.get` | - | done |
| V2 | Arrangement side by side / stacked, divider position | yes `App/ContentView.swift:76`, `App/EditorLayout.swift:134,58` | `view.set {arrangement, splitFraction}` | - | done |
| V3 | 3D in separate window / dock back | yes `App/ContentView.swift:86`, `App/EditorLayout.swift:139-142` | `view.set {detach3D: bool}`, `view.get` reports `detach3D` | - | done |
| V4 | Show / hide inspector, sidebar tab (Levels / Objects / Catalog) | yes `App/ContentView.swift:98`, `Panels/SidebarView.swift:18` | `view.set {inspector, sidebar, statusBar, sidebarTab}` | - | done |
| V5 | Orbit, pan, zoom, pinch, walk (first person) | yes: `Scene/SceneCamera.swift`, `Scene/SceneTrackpad.swift` (pinch, two-finger pan/orbit, walk with keys) | `camera.set_state` (any pose) | - | Agent poses the camera with `camera.set_state` |
| V6 | Camera mode orbit / first person / top / free | yes `Scene/SceneView.swift:55` (3D overlay mode switch Orbit / Free / Top / Aerial / First person) | `camera.set_state {mode}`, `camera.preset` | - | - |
| V7 | Aerial (bird's-eye) preset | yes `Scene/SceneView.swift:8` (3D overlay mode "Aerial") | `camera.preset {preset: aerial}`, `render.scene_image {preset: aerial}` | - | Fitted to the level; for pictures fitted to the picture's own size |
| V8 | Reset camera, frame bounds | yes `Scene/SceneView.swift:108,113` (3D overlay Frame / Reset) | `camera.preset {preset: reset\|frame, ids?}` | - | No separate menu item; the overlay buttons are the UI |
| V9 | Field of view | yes `Scene/SceneView.swift` Display popover slider (20-110°, not in Top) | `camera.set_state {fovDeg}` | - | - |
| V10 | Save current camera as named view | yes `Scene/SavedViewsPopover.swift` (3D overlay "Saved views": name field + Save; same name replaces) | `camera.save` | - | - |
| V11 | Apply (jump to) a saved camera | yes `Scene/SavedViewsPopover.swift` (click a view in the list) | `camera.apply {id\|name}` | - | - |
| V12 | Rename / delete saved camera | yes `Scene/SavedViewsPopover.swift` (pencil / trash per view, undoable) | `scene.rename_object`, `scene.delete_objects` | - | - |
| V13 | Wall transparency (semi-transparent walls) | yes: "Wall opacity" slider in the 3D display popover (`AppModel.wallOpacity`) | `view.set {wallOpacity}` | - | Also used by `render.scene_image` |
| V14 | Level display in 3D (all levels / active level only / isolate) | yes: "Only active level", "Ceilings" and "Lamps" in the 3D display popover (also Settings > Appearance); "Lamps" off hides lamp furniture but not its light | `view.set {onlyActiveLevel, showCeilings, showLamps}` | - | Also used by `render.scene_image` |
| V15 | Pick in 3D, hover | yes: click to select, hover highlight (`Scene/SceneRenderer+Interaction.swift:60`, `SceneMaterials.swift`) | `scene.select_objects` | - | - |
| V15b | Measure tool in 3D: click two surface points, a line and a label (distance, dx/dy/dz) stay on the points while the camera moves; third click starts anew, Esc clears | yes `Scene/SceneRenderer+Measure.swift:47`, `Scene/SceneRenderer+Interaction.swift` (Measure tool in the toolbar) | `geometry.measure_distance` (distance between two given points) | - | UI-only; selection, gizmo and dragging are off while the tool is active; not in first person |
| V16 | Gizmo: move on axes, rotate ring | yes: move arrows and rotate ring (`Scene/Gizmo.swift`, drag in `SceneRenderer+Interaction.swift`); X/Y arrows of furniture and groups stop flush at walls and furniture (no sliding off the axis) | `scene.move_objects`, `scene.rotate_objects` | - | Contact stop is a drag aid; agents place exactly |
| V16b | Drag furniture over the floor in 3D with magnetic contact (select first, then drag; stops flush, slides along faces, goes through when pulled about 200 mm further; Option or snap off disables; Esc cancels) | yes `Scene/SceneRenderer+FurnitureMove.swift`, `MoveContact` in `Geometry/MoveContact.swift` | `scene.move_objects` | - | Interactive drag aid, no agent counterpart needed; agents move exactly |
| V17 | Drag library item into 3D | yes: drop onto the floor of the active level (`Scene/SceneDrop.swift`, grid snap, Option disables) | `catalog.insert_builtin` | - | Wall snapping on drop stays a plan feature |
| V18 | State change animation | yes `Scene/SceneAnimation.swift` (plays when the 3D view applies a state) | `furniture.activate_state` (animation plays in the live view) | - | `render.*` should wait for the animation to finish |
| V19 | Read current view state (layout, plan viewport, visible 3D settings) | n/a | `view.get` | - | done |
| V20 | Light: time of day, date, north, latitude, mood, exposure, sun shadows | yes `Scene/SceneView.swift:158-165` (3D overlay "Light" popover), `Panels/LightPanel.swift:13-47` | `light.get`, `light.set` | - | `light.set {applyMoodTime}` sets the time suggested by the mood |
| V21 | Lamps in a furniture design: add, change (point or spot, brightness, warmth or colour, range, cone, aim), remove | yes `Panels/InspectorLight.swift:26,58-110` (furniture inspector, section "Light") | `light.set_emitter`, `light.remove_emitter` | - | At most 8 lamps per design are lit at once |
| V22 | Switch the lamps of a placed piece on or off | yes `Panels/InspectorLight.swift:17` | `light.toggle` | - | Undoable like any edit |
| V23 | Walk mode settings: body and eye height, speeds, field of view (standard or calibrated to the screen), collision, head bob, scale bar, mouse and controller | yes `Scene/SceneView.swift:126,166-175` (shown in first person), `Scene/WalkSettingsPopover.swift:56-116` | `walk.get`, `walk.set` | - | View state of the user, not in the project file; no undo step |
| V24 | Open, close or tilt a door, window or balcony door while walking | yes: key E or double click turns, Shift+E or Option+double click tilts (`Scene/SceneRenderer+Interaction.swift`, `Scene/WalkController.swift`, help in `Scene/WalkSettingsPopover.swift`) | `walk.toggle_door {mode}` | - | Sliding doors stay closed; fixed and too small windows stay closed; open state is view state |
| V25 | Free camera (fly with W A S D / Q E, mouse look, editing stays possible) | yes `Scene/SceneView.swift:7-30` (3D overlay mode "Free"), `Scene/SceneRenderer+Frame.swift` (`tickFlight`), `Scene/SceneRenderer+Interaction.swift` (`keyDown`) | `camera.set_state {mode: free}`, `camera.save`, `camera.apply`, `render.scene_image {camera: {mode: free}}` | - | Stored in the project camera (schema 4); the agent sets the eye in `target`. Gizmo and selection tint are off in First person (UI only; `render.scene_image` also shows no tint there) |

## 8. Settings

| # | Capability | UI | Agent | Gap | Proposal |
|---|---|---|---|---|---|
| T1 | Display unit | yes `Panels/SettingsView.swift:12` | `project.update_settings {displayUnit}` | - | - |
| T2 | Snap on / grid / walls / objects, grid size, tolerance, angle step | yes `Panels/SettingsView.swift:18-27` | `project.update_settings` (`snapEnabled`, `snapToGrid`, `snapToWalls`, `snapToObjects`, `gridMm`, `snapToleranceMm`, `angleStepDeg`) | - | - |
| T3 | Collision warnings | yes `Panels/SettingsView.swift:31` | `project.update_settings {collisionWarnings}` | - | - |
| T4 | Default wall thickness / height | yes `Panels/SettingsView.swift:36-38` | `project.update_settings` | - | - |

## 9. Export and images

Export UI is being rebuilt (`Import/ExportActions.swift` is modified); core writers `PlanExport.svg/pdf` and `SceneExport.obj` already exist in RoomsmithCore.

| # | Capability | UI | Agent | Gap | Proposal |
|---|---|---|---|---|---|
| X1 | Export plan as PDF / SVG with paper, orientation, scale, active or all levels | yes `Panels/ExportCommands.swift:13-14`, `Import/ExportActions.swift:43-55,72` | `export.plan {format: pdf\|svg}` | - | done; PNG is X2 (`render.plan_image`) |
| X2 | Export plan as PNG | yes `Panels/ExportCommands.swift:15` (app-side rendering) | `render.plan_image` (PNG via the shared renderer; `export.plan` stays SVG/PDF) | - | done |
| X3 | Export 3D model as OBJ (+MTL), active level or all visible | yes `Panels/ExportCommands.swift:17` | `export.obj` | - | done |
| X4 | "Page too small" fix choices (larger paper, fit to page, anyway) | yes `Import/ExportActions.swift:128-131` | n/a | - | `export.plan` returns an error with the fitting options; `fitToPage:true` option |
| X5 | Scene image of the 3D view from the current or a saved camera | yes `Panels/ExportCommands.swift:22` (File > Export > 3D View as Image) | `render.scene_image {camera?, preset?, ids?, width, height, dark?, path?}` | - | Inline MCP image or file; a saved view via `camera.apply` first or its keys in `camera` |
| X6 | Plan image returned inline for the agent to look at | no | `render.plan_image` | - | done: inline as MCP image content, or `path` |
| X7 | Screenshot of the whole window | no | no | - | by design: covered by X5/X6; no separate tool |

## Totals

Counted from the tables (rows, not tools). Agent tools: 120 in 18 families (`app` 5, `project` 7, `scene` 17, `geometry` 14, `catalog` 7, `furniture` 21, `background` 3, `material` 4, `camera` 5, `view` 2, `render` 2, `history` 2, `export` 2, `report` 3, `walk` 4, `light` 5, `workspace` 5, `library` 12; `scene.check_collisions` and `scene.transfer_objects` counted in `scene`). Without a row of its own: `walk.measure` (a read for agents: eye height above a worktop, window sill, clear door size, gap between two pieces; the app has no counterpart) and the reads that show the same data as the UI.

See the end of "Gaps to close" for the counts.

## Gaps to close

Sizes: S = under a day, one tool or one control, existing Core code; M = new Core extraction or UI panel with tests; L = needs the live 3D view or a rendering path.

### Agent gaps (UI can do it, the agent cannot)

Priority 1: needed so an agent can produce and check results end to end

| Pri | Gap | Rows | Tool proposal | Size |
|---|---|---|---|---|
| A1 (done) | Export plan PDF / SVG / PNG | X1, X2 | `export.plan {format, path, levelId?, allLevels?, paper, orientation, scale}` | M (PNG needs the app renderer) |
| A2 (done) | Export OBJ | X3 | `export.obj {path, levelId?, allVisible?}` | S |
| A3 (done) | View state: layout, arrangement, active level, plan zoom / fit, inspector | V1, V2, V4, P16, L5, V19 | `view.set {layout?, arrangement?, splitFraction?, activeLevelId?, planViewport?{center, mmPerPoint}\|fit?, sidebarTab?, inspector?}` + `view.get` (no undo, no revision) | M |
| A4 (done) | Camera presets and framing (aerial, reset, top, frame ids) | S2, V7, V8 | `camera.preset {preset, ids?}` and/or `view.frame {ids?}` | S |
| A5 (done) | Apply saved camera | V11 | `camera.apply {id\|name}` | S |
| A6 (done) | Wall transparency and level isolation in 3D | V13, V14 | `view.set {wallOpacity, levels}` (after the UI/model state exists) | M |
| A7 (done) | Scene image of the 3D view and plan image, inline | X5, X6 | `render.scene_image`, `render.plan_image` (image content in the MCP result) | L |

Priority 2: editing completeness

| Pri | Gap | Rows | Tool proposal | Size |
|---|---|---|---|---|
| A8 (done) | Update level (rename, elevation, height, visible, locked) | L2 | `geometry.update_level` | S |
| A9 (done) | Update dimension | P6 | `geometry.update_dimension` | S |
| A10 (done) | Rename any object | S11, V12 | `scene.rename_object {id, name}` | S |
| A11 (done) | Project rename | F5 | `project.rename` or `name` in `project.update_settings` | S |
| A12 (done) | Update existing furniture design | B4 | `furniture.update_definition` | M |
| A13 (done) | Delete state / animation, set animation per from-state | B5, B6 | `furniture.delete_state`, `furniture.set_animation` | S |
| A14 (done) | Delete definition, product, saved camera, material | C13 | extend `scene.delete_objects` kinds (refuse when still referenced) | S |
| A15 (done) | Align | S10 | `scene.align_objects {ids, edge}` | S |
| A16 (done) | Room from enclosed walls | P3 | `geometry.create_room_from_walls {point}` (move `PlanNSView.face(containing:)` into Core) | M |
| A17 (done) | Template-based furniture | B2 | `furniture.create_from_template` | M |
| A18 (done) | Configuration rename / duplicate | C11 | `furniture.update_configuration` | S |

Priority 3: file level and imports

| Pri | Gap | Rows | Tool proposal | Size |
|---|---|---|---|---|
| A19 (done) | New / open / save as | F1, F2, F4 | `project.new`, `project.open`, `project.save_as` (explicit `discard`, path allow-list) | M |
| A20 (done) | Import 3D model | C14 | `catalog.import_model {path, name?, place?}` | M |
| A21 (done) | Background image add / calibrate | P13, P15 | `background.add`, `background.calibrate`, `background.update` | M |
| A22 (done) | Material editor | C12 | `material.create`, `material.update` | M |

### UI gaps (the agent can do it, the app cannot; or neither)

| Pri | Gap | Rows | UI location proposal | Size |
|---|---|---|---|---|
| U1 (done) | 3D view incl. orbit / pan / zoom / walk, picking, gizmo, drop, animation | V5, V15, V16, V17, V18 | `Scene/SceneView.swift`, `SceneRenderer+Interaction.swift`, `SceneDrop.swift` | L |
| U2 (done) | Saved cameras: save, apply, rename, delete list | V10, V11, V12 | "Saved views" popover in the 3D overlay (`Scene/SavedViewsPopover.swift`) | M |
| U3 (done) | Camera mode switch, aerial, reset, frame, FOV | V6, V7, V8, V9 | segmented control and buttons in the 3D overlay; View menu items with shortcuts | S |
| U4 (done) | Wall transparency + level display in 3D | V13, V14 | slider and toggle in the 3D overlay; state stored as view state, optional in the project file for exports | M |
| U5 (done) | Scene image export (current / saved camera) | X5 | `File > Export > 3D View as Image...` | M |
| U6 (done) | Import background image, background inspector, reachable calibrate tool | P13, P14, P15 | `File > Import Background Image...`, inspector section, button that sets `EditorTool.calibrate` | M |
| U7 (done) | Delete design / product / saved camera | C13 | catalog context menu (designs, products, materials: only unused entries, else an error with the user count; `Project.deleteUnusedCatalogEntry`); saved cameras in the 3D overlay "Saved views" popover | S |
| U8 (done) | Material editor | C12 | sidebar section or sheet | M |
| U9 | Replace the model of a placed piece (or all pieces of a design) | C18 | inspector picker; `AppModel.perform` around `Project.replaceDefinition` | M |

### Counts (this snapshot)

120 capability rows. 118 are at parity; X7 is by design (covered by X5/X6), so it is not counted as a gap. Gap column: 0 agent-only gaps, 1 UI-only gap (C18), 0 on both sides. Open work item: U9 (UI for replacing a model); A1-A22 and U1-U8 above are done.
Recount with `grep -E '^\| [FSPLCBVTX][0-9]+[a-z]? ' docs/PARITY.md` (row IDs may carry a letter suffix such as P6b) and the Gap column. Update this file with every tool or UI command added or removed, and keep `docs/MCP_API.md` in sync.
