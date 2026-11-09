# Architecture

## Targets (`Package.swift`)

| Target | Kind | Contents | Depends on |
|---|---|---|---|
| `RoomsmithCore` | library | Model, Geometry, Commands, Persistence, Catalog, Export, Lighting, Walk, Library, Reports, Presenter, Agent tool API. Foundation/CoreGraphics only: no AppKit, no RealityKit | none |
| `RoomsmithIPC` | library | Local transport: Unix domain socket, newline-delimited JSON, framing, token handshake | Core |
| `Roomsmith` | executable | macOS app: SwiftUI shell, AppKit 2D plan view, RealityKit 3D view, inspector, socket server host | Core, IPC |
| `roomsmith-mcp` | executable | MCP stdio server and CLI that talks to the running app | Core, IPC |
| `RoomsmithCoreTests` | tests | Unit, property, roundtrip, command and IPC tests | Core, IPC |

Platform: macOS 26+, Apple Silicon, Swift 6 language mode. No third-party packages.

## Layers inside `RoomsmithCore`

| Layer | Path | Responsibility |
|---|---|---|
| Model | `Model/` | Value-type entities, `MM = Int64`, `P2`/`P3`, units and limits |
| Geometry | `Geometry/` | Wall outlines and joins, room polygons, triangulation, meshes for primitives, furniture resolver (definition + state + instance to world geometry), measurements |
| Commands | `Commands/` | Typed commands, validation, inverse commands, transactions, revisions (`DocumentStore`, `Edits*.swift`, `Validator.swift`, `ChangeSet.swift`) |
| Persistence | `Persistence/` | Markdown project codec (see [FILE_FORMAT.md](FILE_FORMAT.md)), atomic save, backups, migration |
| Catalog | `Catalog/` | Product search, filters, built-in parametric templates (own designs), parametric builder specs |
| Furniture | `Furniture/` | Placement, top-view outline, `FurnitureTransfer` (packs furniture with its designs, materials and asset bytes so it can move between two open projects) |
| Lighting | `Lighting/` | `SunPosition` (sun from date, time, latitude, north) and `LightRig` (sun, sky and the lamps that shine, as plain data); the settings themselves are in `Model/Lighting.swift` and are part of the document |
| Walk | `Walk/` | Walk settings, motion, collision against walls, openings and furniture, measuring; pure logic without UI. The settings are user view state, not document state |
| Library | `Library/` | `LibraryStore`: the global furniture library on disk (outside every project); `Library/FromPhoto/`: turning photo analysis into a template choice, dimensions and parameters (the Vision call itself is in the app) |
| Export | `Export/` | SVG, PDF, PNG raster, OBJ |
| Reports | `Reports/` | Bill of materials, room report, clearance check |
| Presenter | `Presenter/` | HLS encoder and server, composition for AirPlay and the second display (see [PRESENTER.md](PRESENTER.md)) |
| Benchmark | `Benchmark/` | Generated stress project for the performance numbers |
| Agent | `Agent/` | Tool definitions, schemas, handlers on top of commands and queries (`Tools*.swift`, `ToolRegistry.swift`), audit log |

Dependencies point downward: Agent and Export read Model/Geometry; only Commands mutate the document. Library and Walk are the exception to "document state": the library lives in the user's support folder and the walk settings in the app defaults.

## Data flow

```
UI gesture / agent request
        -> Command (typed, validated, carries expectedRevision and origin)
        -> DocumentStore (MainActor): apply, revision++, push undo entry
        -> ChangeSet (affected entity ids + kind)
        -> 2D renderer (invalidate dirty rects)   3D renderer (update/add/remove entities)
        -> Event stream (agents: long-poll, audit log)
```

- The store is the single source of truth. Views hold no document state of their own besides selection, hover and transient drag previews.
- Renderers update incrementally from the ChangeSet; a full scene rebuild only happens on project open.
- A drag in the UI previews with transient values and commits one command on release, so one gesture is one undo step. While a human drags, the entities are marked busy; agent commands touching them fail with `BUSY`.
- Agent commands carry `expectedRevision`; a content change since that revision returns `CONFLICT` with the current revision (camera-only changes bump the revision but never make it stale, see `DocumentStore.contentRevision`). They run through the same validation and undo stack as UI commands.

## Threading

| Component | Isolation |
|---|---|
| `DocumentStore`, undo stack, selection | `@MainActor` |
| Socket server, client sessions, long-poll waiters | Background tasks; hop to MainActor to execute a command, results returned as `Sendable` values |
| Import (USDZ), mesh generation, export, triangulation of large plans | Background tasks on immutable snapshots of the model |
| Save | Snapshot on MainActor, encoding and file I/O off the main thread, atomic replace |

The UI thread is never blocked by socket I/O or file I/O.

## Coordinates

- Document: X east, Y north, Z up, millimetres (`Int64`). Plan view: X right, Y up (screen Y inverted in one place).
- RealityKit (Y up, metres, `Float`): `x = X/1000`, `y = Z/1000`, `z = -Y/1000`. The mapping and its inverse live in one module and are covered by round-trip tests.
- Rounding: half away from zero. Angles in degrees, normalised to [0, 360), 0.001 degree resolution.
- Zoom, pan, pixel size and snap grid belong to view state and are converted to document values only through the explicit snap/convert functions.

## Rendering

- 2D: custom `NSView` drawing in world coordinates with a view transform; spatial index for hit-testing and snapping.
- 3D: RealityKit `ARView` in non-AR mode with its own camera; entities keyed by document id; gizmo as separate overlay entities; picking by ray cast against a spatial index and entity bounds.

## App structure

Beyond the 2D and 3D views (`Plan/`, `Scene/`), the app target has:

- Workspace (`App/Workspace.swift`, `WorkspaceViews.swift`): the open projects of a window as tabs, the compare split and furniture transfer between projects. Each project is its own `AppModel` with its own store, undo history and selection; tabs and the compare state are app state and are not saved in a project.
- Library UI (`Library/`): sections, search, detail view, thumbnails; `Library/FromPhoto/` has the photo sheet and the Vision provider (on device only).
- Light and walk (`Panels/LightPanel.swift`, `InspectorLight.swift`, `Scene/SceneEnvironment.swift`, `SceneRenderer+Light.swift`, `WalkController.swift`, `WalkSettingsPopover.swift`): the renderer translates `LightRig` and the walk logic from Core into RealityKit and input.
- Agent bridges (`Agent/AppViewBridge.swift`, `AppWalkBridge.swift`, `AgentHost.swift`): tools that need a window (snapshots, walk, workspace, thumbnails, photo analysis) answer `UNSUPPORTED` when no window is open.
- Test hooks (`App/TestHooks.swift`, `AppLaunch.swift`): only active with `ROOMSMITH_TEST_MODE=1`; see [DEVELOPMENT.md](DEVELOPMENT.md).

## Persistence

Package folder `Name.roomsmith/` with `project.md`, `assets/`, `backups/`; atomic writes; details in [FILE_FORMAT.md](FILE_FORMAT.md).

## Agent interface

`roomsmith-mcp` speaks MCP over stdio to the agent client and the IPC protocol over a Unix socket to the app. Details in [MCP_API.md](MCP_API.md).
