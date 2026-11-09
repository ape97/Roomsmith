# Product Specification

Roomsmith is a native macOS app (macOS 26+, Apple Silicon) for dimensionally exact floor plans and furnishing, with a 2D editor, a live 3D view, and a local agent API. Status of each area: see [STATUS.md](STATUS.md). Nothing below is a claim of existing behaviour; it is the target.

## 1. Goals

| # | Goal |
|---|---|
| 1 | Exact geometry: lengths and coordinates stored as integer millimetres, no drift from zoom, pan or rendering |
| 2 | One document: 2D editor, dimensions, room topology, inventory and 3D scene show the same data source |
| 3 | Two working modes (2D plan, live 3D), usable side by side |
| 4 | Direct 3D editing: pick object, X/Y/Z move gizmo, rotation, scale, numeric entry |
| 5 | Furniture and product management with rich product information |
| 6 | Groups with saved configurations, furniture states with animation |
| 7 | Live control by AI agents through a local, documented, authenticated API |
| 8 | Measured performance on large plans |
| 9 | Reproducible repository, tests, public-ready presentation |
| 10 | Self-contained: no cloud or third-party runtime needed |

## 2. Interaction concept

- Window layout: left sidebar (levels, catalog, object tree), centre work area (2D plan, 3D view, or both), right inspector (exact dimensions, materials, product data, states, configurations), status bar (scale, snap, cursor coordinates, agent status).
- Light and dark appearance, high-resolution displays, keyboard shortcuts for all common actions.
- Numeric input accepts mm, cm and m. Stored values are always mm.

### 2D plan

- Draw walls and rooms by click, drag and typed lengths; edit, split, extend, join; non-orthogonal walls supported.
- Dimension lines, grid, orthogonal/angular guides, guide lines, zoom/pan, levels with visibility and locking.
- Doors and windows live in walls and stay attached to them; the wall opening is geometrically correct.
- Background image with calibration from a known reference distance.
- Place furniture from the catalog by drag and drop; rotate, scale, edit numerically.
- Multi-select, copy/paste, align, distribute, duplicate, group, undo/redo.

### 3D live view

- Real-time shading, lights, shadows, materials; UI stays responsive during scene changes.
- Cameras: orbit, pan, zoom, top view, first-person/walkthrough (ego).
- Click object, see selection outline, see three labelled X/Y/Z arrows, drag an axis, object moves live; plane handles, rotation, numeric entry.
- Picking selects the nearest visible object (large, small, transparent, nested).
- Magnetic snapping to grid, walls, floor, edges, centres, neighbours, surfaces and heights; visual preview, adjustable tolerance, temporarily disabled by a modifier key.
- Collision shown as a non-destructive warning; never silently shifts precise dimensions.
- Groups and components editable as a whole or individually.
- Changes appear without reload or app restart.

### Furniture

- Parametric primitives (box, cylinder, plane, slab, cushion, leg, frame), combinable, nestable, savable as a reusable definition.
- Per-component colour, texture, roughness, metallic.
- USDZ import with scale check and error handling. No external modelling tool is required.
- Catalog with search, filter, sort and room/project assignment; a product can exist as a wish-list entry without a placed model.
- Product fields (all optional, extensible): name, category, description, notes, manufacturer, model/article number, URLs, price, currency, price date, dimensions, weight, material/colour, files, images, tags, purchase status, variants, assigned rooms, custom key/value pairs.

### States and configurations

- **State** (one object): e.g. bed folded/unfolded. A state stores per-component pose, visibility, dimensions or asset variant. Transitions animate with defined pivots/keyframes and easing; incompatible meshes use an asset swap or crossfade instead of a fake morph. End states are exact.
- **Group configuration** (several objects): e.g. modular sofa variants 1/2/3. Each configuration stores per-member local position, rotation, visibility, material and state. Configurations can be named, duplicated, saved, loaded and compared. Editing one never changes another.
- Transition animation never alters the stored end transforms.

### Agent API

- Local only (Unix domain socket), token authentication, visible "agent connected / write access" status with an instant write lock, audit log, no shell or arbitrary file access.
- Same command engine as the UI; structured errors; `expectedRevision` conflict detection; objects the human is dragging are `BUSY` for agents; change stream with long-poll; compact paginated answers; batch operations.
- Tool list and schemas: `MCP_API.md` (written separately).

## 3. Data model overview

Stable UUIDs for all entities. Source: `Sources/RoomsmithCore/Model/`.

| Entity | Purpose |
|---|---|
| Project | Root: settings, levels, walls, rooms, openings, dimensions, materials, assets, definitions, instances, groups, catalog, cameras |
| Level | Elevation and height of one storey |
| Wall, Room, Opening (door/window) | Plan geometry; openings reference a wall |
| Dimension | Measured, labelled distance |
| Material, ProjectAsset, BackgroundImage | Appearance and files |
| FurnitureDefinition | Reusable design: components, states, animation tracks |
| FurnitureInstance | Placed exemplar of a definition (pose, state, overrides) |
| FurnitureGroup, GroupConfiguration | Grouped members and saved member poses |
| CatalogProduct, ProductLink | Product information, independent of placement |
| CameraState, SavedCamera | Views |

Product definition and placed instance are separate. Grouping and reparenting preserve world transforms.

## 4. Accuracy requirements

| Topic | Requirement |
|---|---|
| Stored lengths/coordinates | `Int64` millimetres, valid range checked (overflow-safe) |
| Rounding | One rule everywhere: half away from zero |
| Angles | Degrees, normalised to [0, 360), resolution 0.001 degrees |
| Free geometry | `Double` with robust predicates; no claim of exact arithmetic for curves |
| Axes | X east, Y north, Z up; RealityKit mapping x = X/1000, y = Z/1000, z = -Y/1000, in one central place |
| View state | Zoom, pan, pixels and snap grid are separate from document values |
| Print/PDF | Plans are scaled to a stated ratio; physical accuracy also depends on printer calibration and is verified, not assumed |
| Persistence | Save and reopen reproduces identical values |

## 5. Exports

SVG and PDF (to scale), image/screenshot, OBJ (3D). Further formats go to the backlog. File format: [FILE_FORMAT.md](FILE_FORMAT.md) (written separately).

## 6. Non-goals

- No cloud service, account or telemetry.
- No web view as a substitute for native UI.
