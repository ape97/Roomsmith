# Roomsmith agent tool API (MCP_API)

Reference of all 120 tools an agent (Claude Code or any MCP client) can call. The same list is available at runtime
from `app.list_tools` (JSON schemas included). Setup and example prompts: `AGENT_GUIDE.md`.

Source of truth: `Sources/RoomsmithCore/Agent/Tools*.swift` and `ToolRegistry.swift`. The tool sections below were
generated from the tool descriptors; keep them in sync when a tool changes (the test `exposesAll120ToolsInFamilies` guards the names).

## How it is wired

```
Claude Code --stdio MCP--> roomsmith-mcp --Unix socket + token--> Roomsmith.app (AgentHost) --> ToolRegistry --> DocumentStore
```

* Socket: `~/Library/Application Support/Roomsmith/agent.sock` (0600), token file `agent-token` next to it. The MCP helper
  reads the token itself; the token never appears in tool arguments, results or the audit log.
* Overrides (tests): `ROOMSMITH_SUPPORT_DIR`, `ROOMSMITH_SOCKET`, `ROOMSMITH_TOKEN_FILE`.
* Audit log: `~/Library/Application Support/Roomsmith/agent-audit.jsonl` (JSON Lines, rotated at 5 MB): time, clientId, tool,
  argument summary (<= 300 chars), ok / error code, revision, duration.
* There is no shell tool and no arbitrary file access. `project.save` writes only to the project's own file.

## Conventions

| Topic | Rule |
|---|---|
| Lengths | integer millimetres (`...Mm` suffix in names). X east, Y north, Z up. Points are `{"x":1000,"y":2000}` (`z` optional where it makes sense). |
| Sizes | `{"width":..., "depth":..., "height":...}` in mm. |
| Angles | degrees (double, finite), counter-clockwise seen from above. Object rotations (`rotationDeg`, `degrees`, `rotation`): at 0 the local X axis of a piece points east and its back faces north (front south); 90 = front east, 180 = front north, 270 = front west. Camera `yawDeg`: 0 = north (+Y) -- a different zero. Stored angles are normalised to [0, 360) and rounded to 1/1000 degree. |
| Input limits | Every length, coordinate, delta, offset, height and elevation (all `...Mm` fields, point and size members) must be a whole number of millimetres within ±100 000 000 (±100 km). Larger values fail with `OUT_OF_RANGE` before anything is computed; sizes must additionally be 1...100 000 mm (checked on commit, `OUT_OF_RANGE`). |
| Output values | `...Mm` results are never capped. Computed values may exceed the input limit (a wall from -1e8 to 1e8 is 200 000 000 mm long, a diagonal up to about 282 842 712 mm); they are reported exactly, rounded to whole mm. A value that is not finite or does not fit a 64-bit integer is `null`, never 0 or a clamped number. |
| Non-integer mm | `1000.5` or a string where a number is expected fails with `INVALID_ARGUMENT`; values are never rounded. |
| Paging | `limit` 1...500; a `cursor` must be one returned by the same tool (non-numeric, negative or oversized cursors fail with `INVALID_ARGUMENT`). |
| Batch / history | `app.batch` accepts 1...100 steps; `dryRun` and `expectedRevision` belong to the batch, not to a step (`INVALID_ARGUMENT`). `history.undo`/`redo` with `steps` > 1 either perform all steps or fail without a change (`INVALID_ARGUMENT` if fewer are available, `BUSY` while the user is editing). |
| Prices | integer minor units (cents) in `priceMinor`. |
| Ids | lowercase UUID strings. Input accepts upper or lower case. |
| Names | wherever a *material*, *state* or *configuration* is expected you may pass the id or the exact (case-insensitive) name. |
| Revisions | the project has a `revision` (bumped by every committed change); every object has its own `rev`. |

## Reading: lists

List tools (`scene.list_objects`, `catalog.search_products`, `catalog.list_builtin`, `furniture.list_definitions`, `scene.check_collisions`,
`project.get_scene_snapshot`) are paginated:

* `limit` default 50 (snapshot: 200), maximum 500. `cursor` is the `nextCursor` string of the previous page (an offset).
* Result: `{items, total, nextCursor?, revision}`. `nextCursor` is absent on the last page. Order is stable as long as the project does not change.
* Filters: `kind`, `levelId`, `query` (case-insensitive name substring), `category`.
* A row is `{id, kind, name, rev, levelId, ...short geometry}`; `scene.get_object` returns the full detail of one object.

## Writing: common arguments and response

Every mutating tool accepts:

| Argument | Meaning |
|---|---|
| `dryRun` (bool) | Validate and report `changes` without changing anything (`committed: false`, `dryRun: true`). Allowed even while write access is off. |
| `expectedRevision` (int) | Fail with `CONFLICT` if document content changed since this revision. Camera moves (user or `camera.set_state`) raise `revision` for subscribers but never make it stale. |
| `expectedObjectRevisions` (`{uuid: rev}`) | Fail with `CONFLICT` if any listed object changed since you read its `rev`. This is the normal way to avoid overwriting the user's edits. |

Unknown argument names are rejected with `INVALID_ARGUMENT` (the message lists the allowed ones).

Response of every mutating tool (plus tool-specific fields, e.g. `id`):

```json
{ "committed": true, "revision": 42,
  "changes": [ {"id": "...", "kind": "furniture", "op": "modified", "rev": 7} ],
  "changeCount": 1, "changesTruncated": false }
```

* `changes` is capped at 200 entries (`changeCount` has the real number, `changesTruncated` tells). `op` is `added`, `modified` or `removed`.
* Success is only reported **after** the change is committed. `committed: false` without `dryRun` means the request changed nothing (no difference).
* Each mutating call is exactly **one** undo step, shown to the user as "Agent: ...", and the change event carries the origin `agent:<clientId>`.
* A mutating tool never changes anything when it returns an error.

## Errors

An error has `code`, `message` (plain English, says what to do) and optional `details`.

| Code | Meaning |
|---|---|
| `UNKNOWN_TOOL` | No such tool. Call `app.list_tools`. |
| `INVALID_ARGUMENT` | Missing, mistyped or out-of-range argument; the message names the field (e.g. `Argument 'ids': ...`). |
| `NOT_FOUND` | An id, name, level, material, state or configuration does not exist. |
| `OUT_OF_RANGE` | A value is outside the allowed range. `export.plan`: the plan does not fit the paper at that scale; `details` has the needed size and a paper that fits. |
| `UNSUPPORTED` | The request is valid but not offered (`export.plan` with `format: png`). |
| `CONFLICT` | `expectedRevision` / `expectedObjectRevisions` no longer match. `details` lists the objects. Re-read, then retry. |
| `LOCKED` | The object is locked (`scene.set_locked`). |
| `WRITE_LOCKED` | The user switched off "Allow agents to change the project". Read-only tools and dry runs still work. |
| `BUSY` | The user is currently dragging/editing an object this call would change (also multi-step undo/redo while any edit is in progress); `details.ids` names them. Nothing was changed; retry shortly. |
| `NO_FILE` | `project.save` or `catalog.import_model` on a project that has no file yet (use `project.save_as` first). |
| `UNAUTHORIZED`, `NOT_RUNNING` | Socket level: wrong token, app not running. |
| `INTERNAL` | Unexpected; report it. |

## Batches

`app.batch` runs several mutating tools in **one** commit: one revision, one undo step. If any step fails, nothing changes and the
error carries the failing step's code with `details.step` (0-based) and `details.tool`. Maximum 100 steps. Create tools accept an
optional `id` (lowercase UUID) so later steps of the same batch can refer to objects created earlier. Each step may carry its own
`expectedObjectRevisions` in its `arguments`.

```json
{"steps":[
  {"tool":"geometry.create_wall","arguments":{"id":"7b2d5e0e-0000-4000-8000-000000000001","start":{"x":0,"y":0},"end":{"x":4000,"y":0}}},
  {"tool":"geometry.add_opening","arguments":{"wallId":"7b2d5e0e-0000-4000-8000-000000000001","type":"door"}}
]}
```

## Following changes

`app.subscribe_changes` is a long poll. Call it once without `afterSeq` to get `latestSeq`, then repeatedly with `afterSeq` = the last
`latestSeq` and `timeoutMs` up to 30000. It returns as soon as events exist, or empty after the timeout. The MCP client call timeout is 60 s,
so keep `timeoutMs` below that.



## App (`app.*`)

### `app.get_capabilities`  (read-only)

Version, limits, units, conventions and whether agents may currently change the project. Call this first.

Arguments: none.

**Result:** `{app, appVersion, apiVersion, writeEnabled, toolCount, units, limits, concurrency, errorCodes, revision}`

**Undo:** No undo (read-only).

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND` (unknown ids).

### `app.get_active_project`  (read-only)

Name, file path, revision, dirty flag, levels, active level, selection and undo state of the open project.

Arguments: none.

**Result:** `{name, id, path|null, revision, dirty, writeEnabled, activeLevelId, levels[], selection[], undoName, redoName, canUndo, canRedo, lastSeq}`

**Undo:** No undo (read-only).

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND` (unknown ids).

### `app.list_tools`  (read-only)

All tools with their JSON schema (array of descriptors).

Arguments: none.

**Result:** A JSON array of `{name, description, inputSchema, readOnly}` (not wrapped in an object).

**Undo:** No undo (read-only).

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND` (unknown ids).

### `app.subscribe_changes`  (read-only)

Long poll for document changes. Pass the `latestSeq` of the previous answer as afterSeq; the call returns as soon as events exist or after timeoutMs. Without afterSeq it returns immediately with the current latestSeq. `truncated` means events were dropped or the app restarted: re-read the scene.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `timeoutMs` | integer |  | Wait up to this long (0...30000, default 0) when nothing happened yet. |
| `afterSeq` | integer |  | Return events with seq greater than this. |

**Result:** `{events:[{seq, revision, origin, name, kind, changes:{added, modified, removed, total, objects[]}}], latestSeq, truncated, hasMore, revision}`. `truncated: true` means events were dropped (or `afterSeq` is newer than the app): re-read with `project.get_scene_snapshot`.

**Undo:** No undo (read-only).

**Errors:** `INVALID_ARGUMENT` for `timeoutMs` outside 0...30000 or a negative `afterSeq`.

### `app.batch`  (mutating)

Runs several mutating tools atomically: one undo step, one revision. If any step fails nothing changes and the error names the step. Later steps may use ids that earlier steps created by passing `id` to the create tools. Not allowed as steps: app.batch, history.*, project.save, camera.set_state, read tools.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `steps` | array of object | yes | Steps in order. |

Plus the common arguments `dryRun`, `expectedRevision`, `expectedObjectRevisions` (see above).

**Result:** Mutating response plus `steps: [{index, tool, result}]` (the per-step results, e.g. created ids).

**Undo:** All steps together form ONE undo step ("Agent: batch (N steps)").

**Errors:** The failing step keeps its own code (`INVALID_ARGUMENT`, `NOT_FOUND`, `CONFLICT`, ...) and `details` has `step` (0-based) and `tool`; the message starts "Step N (tool) failed" and ends "Nothing was changed.". Steps may not be `app.batch`, `history.*`, `project.save`, `camera.set_state` or read tools.


## Project (`project.*`)

### `project.get_summary`  (read-only)

Overview of the open project: counts per object kind, bounds, levels, settings, camera, revision, undo state.

Arguments: none.

**Result:** `{name, id, path, revision, dirty, writeEnabled, counts{...}, bounds{min,max,widthMm,depthMm}|null, levels[], activeLevelId, settings, camera, undoName, redoName}`

**Undo:** No undo (read-only).

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND` (unknown ids).

### `project.save`  (mutating)

Saves the open project to its own file. Fails with NO_FILE while the project has never been saved by the user (agents cannot choose a path). Needs write access.

Arguments: none.

**Result:** `{saved: true, path, revision, dirty}`

**Undo:** No undo; clears the "edited" mark.

**Errors:** `WRITE_LOCKED`; `NO_FILE` while the project was never saved by the user (agents cannot choose a path).

### `project.get_scene_snapshot`  (read-only)

Compact overview of the whole scene as text (one line per object with full ids) or JSON rows, paginated. Good first call to orient yourself.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `levelId` | uuid |  | Only this level. (lowercase UUID) |
| `cursor` | string |  | `nextCursor` of the previous page. |
| `format` | `text` \| `json` |  | `text` (default) or `json`. |
| `limit` | integer |  | Page size, default 50, maximum 500. |

**Result:** `format=text`: `{text, total, revision, nextCursor?}` (one line per object, full ids). `format=json`: a page of list rows.

**Undo:** No undo (read-only).

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND` (unknown ids).

### `project.update_settings`  (mutating)

Changes the project name and settings; only the given keys change. Returns the name and the full settings.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `name` | string |  | New project name (not empty). |
| `snapToObjects` | boolean |  | Snap to other objects. |
| `snapToWalls` | boolean |  | Snap to walls. |
| `snapToGrid` | boolean |  | Snap to the grid. |
| `displayUnit` | `mm` \| `cm` \| `m` |  | Unit shown in the UI. |
| `snapToleranceMm` | integer |  | Snap distance in mm (0...10000). |
| `defaultWallThicknessMm` | integer |  | Thickness of new walls. |
| `snapEnabled` | boolean |  | Master switch for snapping. |
| `defaultWallHeightMm` | integer |  | Height of new walls. |
| `gridMm` | integer |  | Grid size in mm (1...10000). |
| `angleStepDeg` | number |  | Rotation snap step in degrees (>0, <=180). |
| `collisionWarnings` | boolean |  | Show collision warnings. |

Plus the common arguments `dryRun`, `expectedRevision`, `expectedObjectRevisions` (see above).

**Result:** Mutating response plus `name` and `settings` (all settings after the change).

**Undo:** One undo step named "Agent: update settings". `dryRun` creates none.

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND`, `WRITE_LOCKED`, `CONFLICT` (stale revisions), `LOCKED`, `OUT_OF_RANGE`, `BUSY`.


### `project.new`  (action)

Replaces the open project by a new empty one (untitled, default level). Needs write access. Unsaved changes are never dropped silently: while the project is dirty the call fails with `CONFLICT` unless `discard` is true. Clears the undo history. No dialog is shown.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `discard` | boolean |  | Drop unsaved changes of the open project (default false). |

**Result:** `{name, id, path (null), revision, dirty, activeLevelId, levels[{id, name}], warnings[]}`

**Errors:** `WRITE_LOCKED`, `CONFLICT`.

### `project.open`  (action)

Opens an existing `.roomsmith` package (absolute path of the folder) in place of the open project. Needs write access. `CONFLICT` while the open project has unsaved changes unless `discard` is true. Clears the undo history. No dialog is shown.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `path` | string | yes | Absolute path of an existing `.roomsmith` package. |
| `discard` | boolean |  | Drop unsaved changes of the open project (default false). |

**Result:** like `project.new`, with the file `path` and load `warnings`.

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND`, `WRITE_LOCKED`, `CONFLICT`.

### `project.save_as`  (action)

Saves the open project as a new `.roomsmith` package and makes it the project's file (later `project.save` writes there). Needs write access. `path` must be absolute, end in `.roomsmith`, lie in an existing folder and not be the open package. An existing package is replaced only with `overwrite` (`INVALID_ARGUMENT`, `details.existing`); a folder that is not a Roomsmith package is never replaced. There is no `discard`: saving loses no changes.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `path` | string | yes | Absolute target path ending in `.roomsmith`. |
| `overwrite` | boolean |  | Replace an existing package at that path (default false). |

**Result:** `{saved: true, path, revision, dirty}`

**Errors:** `INVALID_ARGUMENT`, `WRITE_LOCKED`.

## Scene objects (`scene.*`)

### `scene.list_objects`  (read-only)

Lists objects (paginated): rows with id, kind, name, rev, levelId and short geometry. Default kinds: level, wall, room, opening, dimension, furniture, group.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `kind` | `level` \| `wall` \| `room` \| `opening` \| `dimension` \| `furniture` \| `group` \| `material` \| `definition` \| `product` |  | One kind, or omit for the floor-plan kinds. |
| `query` | string |  | Case-insensitive substring of the name. |
| `limit` | integer |  | Page size, default 50, maximum 500. |
| `levelId` | uuid |  | Only objects on this level. (lowercase UUID) |
| `category` | string |  | Furniture/definition/product category, e.g. "sofa" (exact, case-insensitive). |
| `cursor` | string |  | `nextCursor` of the previous page. |
| `roomId` | uuid |  | Only furniture and groups whose position lies inside this room. (lowercase UUID) |

**Result:** `{items:[row], total, nextCursor?, revision}`; row = `{id, kind, name, rev, levelId, ...short geometry}`. Furniture rows also carry `locked`, `visible` and `allowsOverlap`.

**Undo:** No undo (read-only).

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND` (unknown ids).

### `scene.get_object`  (read-only)

Full detail of one object: rev, geometry, footprint bounding box, state, group, product, definition components/states.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `id` | uuid | yes | Object id. (lowercase UUID) |

**Result:** Row fields plus the full detail of the object (geometry, `footprint` bounds, `state`, `group`, `product`, definition components and states).

Note for openings: the detail is the stored opening, so its keys are the model names, not the argument names of `geometry.add_opening` / `geometry.update_opening`. The frame width is output as `frameWidth` (input: `frameWidthMm`) and the glass type as `glassType` (input: `glass`); `style`, `handle`, `mullionCols` and `mullionRows` keep their names.

**Undo:** No undo (read-only).

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND` (unknown ids).

### `scene.select_objects`

Reads or changes the selection shown in the app (does not change the document). Modes: replace (default), add, remove, clear, get. It is not read-only: every mode except `get`, and any call with `levelId`, changes what the app shows and needs write access (`WRITE_LOCKED` when the user switched agents off). `mode: get` without `levelId` works while writing is locked.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `ids` | array of string |  | Object ids. |
| `mode` | `replace` \| `add` \| `remove` \| `clear` \| `get` |  | How to apply `ids`. |
| `levelId` | uuid |  | Also make this level the active one. (lowercase UUID) |

**Result:** `{selection: [uuid]}` (the selection after the call). Does not change the document, no revision, no undo.

**Undo:** No undo; touches only the selection in the app.

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND` (unknown ids), `WRITE_LOCKED`.

### `scene.create_object`  (mutating)

Creates one object. `kind` selects the creating tool (wall, room, opening, dimension, level, furniture, product, group); all other arguments are the arguments of that tool (geometry.create_wall, geometry.create_room, geometry.add_opening, geometry.create_dimension, geometry.create_level, furniture.create_instance, catalog.create_product, scene.group_objects).

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `kind` | `dimension` \| `furniture` \| `group` \| `level` \| `opening` \| `product` \| `room` \| `wall` | yes | What to create. |

Plus the common arguments `dryRun`, `expectedRevision`, `expectedObjectRevisions` (see above).

**Result:** The result of the creating tool (usually `id`) plus the mutating fields.

**Undo:** One undo step named "Agent: create object". `dryRun` creates none.

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND`, `WRITE_LOCKED`, `CONFLICT` (stale revisions), `LOCKED`, `OUT_OF_RANGE`, `BUSY`.

### `scene.move_objects`  (mutating)

Moves objects exactly (no snapping), either by `delta` or, for one object, to the absolute position `to`. Groups move with all members; a lone opening slides along its wall (delta.x along the wall). Millimetres, x east, y north.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `ids` | array of uuid | yes | Objects to move. |
| `delta` | point `{x, y[, z]}` mm |  | Offset to add. Millimetres; z optional. |
| `to` | point `{x, y[, z]}` mm |  | New absolute position of the single object (z optional: keeps the current height). Millimetres; z optional. |

Plus the common arguments `dryRun`, `expectedRevision`, `expectedObjectRevisions` (see above).

**Result:** Mutating response plus `objects: [row after the move]`.

**Undo:** One undo step named "Agent: move objects". `dryRun` creates none.

**Errors:** `NOT_FOUND`, `LOCKED` (locked object), `CONFLICT`, `INVALID_ARGUMENT` (give exactly one of `delta`/`to`; `to` needs one id).

### `scene.rotate_objects`  (mutating)

Rotates objects counter-clockwise by `degrees` around their common centre or the given pivot (millimetres).

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `degrees` | number | yes | Angle to add, counter-clockwise. |
| `ids` | array of uuid | yes | Objects to rotate. |
| `pivot` | point `{x, y[, z]}` mm |  | Rotation centre; default: centre of the objects. Millimetres. |

Plus the common arguments `dryRun`, `expectedRevision`, `expectedObjectRevisions` (see above).

**Result:** Mutating response plus `objects: [row after the rotation]`.

**Undo:** One undo step named "Agent: rotate objects". `dryRun` creates none.

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND`, `WRITE_LOCKED`, `CONFLICT` (stale revisions), `LOCKED`, `OUT_OF_RANGE`, `BUSY`.

### `scene.set_material`  (mutating)

Sets or clears a material. Slots: wallLeft, wallRight, wallBoth, roomFloor, roomCeiling, openingFrame, allComponents (furniture), component:<componentId>.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `ids` | array of uuid | yes | Objects to change. |
| `material` | any |  | Material id or exact name (e.g. from scene.list_objects kind=material); null removes the material. |
| `slot` | string | yes | Where to apply the material. |

Plus the common arguments `dryRun`, `expectedRevision`, `expectedObjectRevisions` (see above).

**Result:** Mutating response plus `objects`.

**Undo:** One undo step named "Agent: set material". `dryRun` creates none.

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND`, `WRITE_LOCKED`, `CONFLICT` (stale revisions), `LOCKED`, `OUT_OF_RANGE`, `BUSY`.

### `scene.group_objects`  (mutating)

Groups furniture into a named group that moves as one.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `ids` | array of uuid | yes | Furniture to group. |
| `name` | string | yes | Group name. |
| `id` | uuid |  | Optional id for the new group (lets later batch steps refer to it). (lowercase UUID) |

Plus the common arguments `dryRun`, `expectedRevision`, `expectedObjectRevisions` (see above).

**Result:** Mutating response plus `id` (the new group).

**Undo:** One undo step named "Agent: group objects". `dryRun` creates none.

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND`, `WRITE_LOCKED`, `CONFLICT` (stale revisions), `LOCKED`, `OUT_OF_RANGE`, `BUSY`.

### `scene.ungroup_objects`  (mutating)

Dissolves groups; the members stay where they are.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `ids` | array of uuid | yes | Group ids. |

Plus the common arguments `dryRun`, `expectedRevision`, `expectedObjectRevisions` (see above).

**Result:** Mutating response plus `ids` of the freed members.

**Undo:** One undo step named "Agent: ungroup objects". `dryRun` creates none.

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND`, `WRITE_LOCKED`, `CONFLICT` (stale revisions), `LOCKED`, `OUT_OF_RANGE`, `BUSY`.

### `scene.delete_objects`  (mutating)

Deletes objects (walls take their openings with them; deleting a group removes its members). Also deletes saved cameras. A material, product or furniture definition that is still used is refused with `INVALID_ARGUMENT`; `details.referenced` lists each blocked id with its `references` (id, kind, name, role). Users deleted in the same call do not block.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `ids` | array of uuid | yes | Objects to delete. |

Plus the common arguments `dryRun`, `expectedRevision`, `expectedObjectRevisions` (see above).

**Result:** Mutating response; `changes` lists everything removed, also dependents (openings of a deleted wall).

**Undo:** One undo step named "Agent: delete objects". `dryRun` creates none.

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND`, `WRITE_LOCKED`, `CONFLICT` (stale revisions), `LOCKED`, `OUT_OF_RANGE`, `BUSY`.

### `scene.rename_object`  (mutating)

Renames any named object: level, room, opening, furniture, group, material, furniture design, product or saved camera. Walls, dimensions and backgrounds have no name.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `id` | uuid | yes | Object to rename. |
| `name` | string | yes | New name; trimmed, not empty. |

Plus the common arguments `dryRun`, `expectedRevision`, `expectedObjectRevisions` (see above).

**Result:** Mutating response plus `id` and `name`.

**Undo:** One undo step. `dryRun` creates none.

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND`, `WRITE_LOCKED`, `CONFLICT` (stale revisions), `LOCKED`, `OUT_OF_RANGE`, `BUSY`.

### `scene.align_objects`  (mutating)

Aligns objects to a common edge of their joint bounds, exact to the millimetre. Group members whose group is also selected are skipped. Openings, levels and backgrounds are ignored; dimensions are aligned like the other objects. Needs at least two targets.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `ids` | array of uuid | yes | Objects to align (2 or more). |
| `edge` | `left` \| `right` \| `top` \| `bottom` \| `centerX` \| `centerY` | yes | Edge of the joint bounds; centers are rounded to whole mm. |

Plus the common arguments `dryRun`, `expectedRevision`, `expectedObjectRevisions` (see above).

**Result:** Mutating response plus `moved` (ids of the objects that actually moved) and `ids` (all aligned targets).

**Undo:** One undo step for the whole alignment. `dryRun` creates none.

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND`, `WRITE_LOCKED`, `CONFLICT` (stale revisions), `LOCKED`, `OUT_OF_RANGE`, `BUSY`.

### `scene.duplicate_objects`  (mutating)

Duplicates objects; the copies are offset (default x 500, y 500). Returns idMap {old: new}.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `ids` | array of uuid | yes | Objects to duplicate. |
| `offset` | point `{x, y[, z]}` mm |  | Offset of the copies. Millimetres; z optional. |

Plus the common arguments `dryRun`, `expectedRevision`, `expectedObjectRevisions` (see above).

**Result:** Mutating response plus `idMap: {oldId: newId}`.

**Undo:** One undo step named "Agent: duplicate objects". `dryRun` creates none.

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND`, `WRITE_LOCKED`, `CONFLICT` (stale revisions), `LOCKED`, `OUT_OF_RANGE`, `BUSY`.

### `scene.set_locked`  (mutating)

Locks or unlocks objects. Locked objects cannot be edited until unlocked.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `ids` | array of uuid | yes | Objects. |
| `locked` | boolean | yes | true locks. |

Plus the common arguments `dryRun`, `expectedRevision`, `expectedObjectRevisions` (see above).

**Result:** Mutating response.

**Undo:** One undo step named "Agent: set locked". `dryRun` creates none.

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND`, `WRITE_LOCKED`, `CONFLICT` (stale revisions), `LOCKED`, `OUT_OF_RANGE`, `BUSY`.

### `scene.set_visible`  (mutating)

Shows or hides objects.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `ids` | array of uuid | yes | Objects. |
| `visible` | boolean | yes | true shows. |

Plus the common arguments `dryRun`, `expectedRevision`, `expectedObjectRevisions` (see above).

**Result:** Mutating response.

**Undo:** One undo step named "Agent: set visible". `dryRun` creates none.

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND`, `WRITE_LOCKED`, `CONFLICT` (stale revisions), `LOCKED`, `OUT_OF_RANGE`, `BUSY`.

### `scene.check_collisions`  (read-only)

Collision warnings of one level: furniture overlapping furniture or walls, blocked openings, furniture outside rooms. Depths in mm.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `ids` | array of uuid |  | Only issues involving these objects. |
| `levelId` | uuid |  | Level; default the active level. (lowercase UUID) |
| `cursor` | string |  | `nextCursor` of the previous page. |
| `limit` | integer |  | Page size, default 50, maximum 500. |

**Result:** `{items:[{type, depthMm, a:{id,name}, b?:{id,name}}], total, nextCursor?, levelId, revision}`; `type` is the collision kind (furniture/furniture, furniture/wall, blocked opening, outside room).

**Undo:** No undo (read-only).

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND` (unknown ids).


### `scene.transfer_objects`  (action)

Copies furniture and furniture groups of the active project into another open project (see `workspace.list`), or moves them with `move: true`. The designs, materials, textures, models and product data travel along; every id is new in the target. Rooms, walls and the group objects themselves are not transferred (a group id expands to its members). Needs the Roomsmith window (`UNSUPPORTED` otherwise) and write access.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `targetProjectId` | uuid | yes | Tab id or project id of the target from `workspace.list`. |
| `ids` | array of uuid | yes | Furniture instance ids (or group ids) of the active project. |
| `move` | boolean |  | Delete the originals after the copy (default false). |

**Result:** `{target, targetProjectId, newIds, moved, deleteError?}`. A move first copies, then deletes; if the delete fails the copy stays and `deleteError` says why. The target needs a saved file when models, textures or product files travel.

**Undo:** One undo step in the target project and, for a move, one in the source project. Not part of `app.batch`.

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND` (ids, target), `CONFLICT`, `LOCKED`, `WRITE_LOCKED`, `UNSUPPORTED`.

## Geometry (`geometry.*`)

### `geometry.create_wall`  (mutating)

Creates a wall from `start` to `end`, or a chain of walls through `points` (closed: also from the last point back to the first). Millimetres; thickness and height default to the project settings.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `start` | point `{x, y[, z]}` mm |  | Start point of a single wall. Millimetres. |
| `closed` | boolean |  | Chain only: close the loop. |
| `levelId` | uuid |  | Level; default the active level. (lowercase UUID) |
| `id` | uuid |  | Optional id of a single wall. (lowercase UUID) |
| `points` | array of point `{x, y[, z]}` mm |  | Points of a wall chain (at least 2). |
| `heightMm` | integer |  | Wall height. |
| `end` | point `{x, y[, z]}` mm |  | End point of a single wall. Millimetres. |
| `thicknessMm` | integer |  | Wall thickness. |

Plus the common arguments `dryRun`, `expectedRevision`, `expectedObjectRevisions` (see above).

**Result:** Mutating response plus `id` (single wall) or `ids` (chain).

**Undo:** One undo step named "Agent: create wall". `dryRun` creates none.

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND`, `WRITE_LOCKED`, `CONFLICT` (stale revisions), `LOCKED`, `OUT_OF_RANGE`, `BUSY`.

### `geometry.update_wall`  (mutating)

Changes a wall. Moving an end point also moves walls that share it unless moveJoined is false.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `start` | point `{x, y[, z]}` mm |  | New start point. Millimetres. |
| `end` | point `{x, y[, z]}` mm |  | New end point. Millimetres. |
| `id` | uuid | yes | Wall id. (lowercase UUID) |
| `heightMm` | integer |  | Height. |
| `moveJoined` | boolean |  | Default true. |
| `rightMaterial` | any |  | Right side. Material id or exact name; null removes it. |
| `leftMaterial` | any |  | Left side (seen from start to end). Material id or exact name; null removes it. |
| `thicknessMm` | integer |  | Thickness. |

Plus the common arguments `dryRun`, `expectedRevision`, `expectedObjectRevisions` (see above).

**Result:** Mutating response. Moving an end point also moves joined walls (`moveJoined`, default true); `changes` lists them.

**Undo:** One undo step named "Agent: update wall". `dryRun` creates none.

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND`, `WRITE_LOCKED`, `CONFLICT` (stale revisions), `LOCKED`, `OUT_OF_RANGE`, `BUSY`.

### `geometry.split_wall`  (mutating)

Splits a wall in two at a point on it. Openings stay with the part they belong to. Returns both new wall ids.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `at` | point `{x, y[, z]}` mm | yes | Point on the wall (projected onto its axis). Millimetres. |
| `id` | uuid | yes | Wall id. (lowercase UUID) |

Plus the common arguments `dryRun`, `expectedRevision`, `expectedObjectRevisions` (see above).

**Result:** Mutating response plus `ids: [first, second]`, `first`, `second`.

**Undo:** One undo step named "Agent: split wall". `dryRun` creates none.

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND`, `WRITE_LOCKED`, `CONFLICT` (stale revisions), `LOCKED`, `OUT_OF_RANGE`, `BUSY`.

### `geometry.create_room`  (mutating)

Creates a room from a closed polygon (corner points in order, at least 3, not self-intersecting).

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `points` | array of point `{x, y[, z]}` mm | yes | Corner points. |
| `levelId` | uuid |  | Level; default the active level. (lowercase UUID) |
| `id` | uuid |  | Optional id. (lowercase UUID) |
| `name` | string | yes | Room name. |

Plus the common arguments `dryRun`, `expectedRevision`, `expectedObjectRevisions` (see above).

**Result:** Mutating response plus `id`.

**Undo:** One undo step named "Agent: create room". `dryRun` creates none.

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND`, `WRITE_LOCKED`, `CONFLICT` (stale revisions), `LOCKED`, `OUT_OF_RANGE`, `BUSY`.

### `geometry.update_room`  (mutating)

Changes a room's name, outline, floor/ceiling material or visibility.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `showFloor` | boolean |  | Draw the floor. |
| `floorMaterial` | any |  | Floor. Material id or exact name; null removes it. |
| `points` | array of point `{x, y[, z]}` mm |  | New outline. |
| `ceilingMaterial` | any |  | Ceiling. Material id or exact name; null removes it. |
| `showCeiling` | boolean |  | Draw the ceiling. |
| `name` | string |  | New name. |
| `id` | uuid | yes | Room id. (lowercase UUID) |

Plus the common arguments `dryRun`, `expectedRevision`, `expectedObjectRevisions` (see above).

**Result:** Mutating response.

**Undo:** One undo step named "Agent: update room". `dryRun` creates none.

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND`, `WRITE_LOCKED`, `CONFLICT` (stale revisions), `LOCKED`, `OUT_OF_RANGE`, `BUSY`.

### `geometry.add_opening`  (mutating)

Adds a door, window or open passage to a wall. `offsetMm` is the distance of the opening's centre from the wall start (default: wall centre). Defaults: door 900x2100, window 1200x1200 with sill 900, opening 1000x2100. The detail arguments (`style`, `handle`, `frameWidthMm`, `mullionCols`, `mullionRows`, `glass`) shape the 3D look only.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `type` | `door` \| `window` \| `opening` |  | Kind of opening (default door). |
| `widthMm` | integer |  | Width. |
| `id` | uuid |  | Optional id. (lowercase UUID) |
| `name` | string |  | Optional name. |
| `wallId` | uuid | yes | Wall. (lowercase UUID) |
| `heightMm` | integer |  | Height. |
| `offsetMm` | integer |  | Centre position along the wall from its start. |
| `sillMm` | integer |  | Height of the lower edge above the floor. |
| `style` | `smooth` \| `panel2` \| `panel4` \| `glass` \| `sliding` \| `tiltTurn1` \| `tiltTurn2` \| `fixed` \| `balconyDoor` \| `balconyDoor2` |  | Look. Doors: `smooth`, `panel2`, `panel4`, `glass`, `sliding`; windows: `tiltTurn1`, `tiltTurn2`, `fixed`, `balconyDoor`, `balconyDoor2` (two-sash balcony door). Must suit the type (default: `smooth` door, `fixed` window). Sliding doors stay closed in walk mode. Tilt-and-turn windows and balcony doors open and tilt in the 3D view (`walk.toggle_door`) unless the opening is too small (inner width under about 200 mm or inner height under about 300 mm per sash); a two-sash style that is too narrow for two sashes gets one. A window that can open gets a `lever` handle when it is added or its style is changed without a `handle` argument; an explicit `none` stays. |
| `handle` | `lever` \| `knob` \| `bar` \| `none` |  | Handle on doors and openable windows (default `none`; a window that can open gets `lever` when the style is set and no handle is given). |
| `frameWidthMm` | integer |  | Frame width 20...150 mm (default 50). |
| `mullionCols` | integer |  | Vertical glazing bars 0...6 (glass door, windows, sliding door). |
| `mullionRows` | integer |  | Horizontal glazing bars 0...6. |
| `glass` | `clear` \| `frosted` \| `tinted` |  | Glass type (default `clear`). |

Plus the common arguments `dryRun`, `expectedRevision`, `expectedObjectRevisions` (see above).

**Result:** Mutating response plus `id`.

**Undo:** One undo step named "Agent: add opening". `dryRun` creates none.

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND`, `WRITE_LOCKED`, `CONFLICT` (stale revisions), `LOCKED`, `OUT_OF_RANGE`, `BUSY`.

### `geometry.update_opening`  (mutating)

Changes an opening: type, size, position, swing, frame material, look details (style, handle, frame width, glazing bars, glass) or the wall it sits in. Detail arguments follow the same rules as in `geometry.add_opening`; a `style` that does not suit the (new) `type` is rejected.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `wallId` | uuid |  | Move the opening to another wall. (lowercase UUID) |
| `inward` | boolean |  | Opens to the left side of the wall. |
| `frameMaterial` | any |  | Frame. Material id or exact name; null removes it. |
| `offsetMm` | integer |  | Centre position along the wall. |
| `heightMm` | integer |  | Height. |
| `sillMm` | integer |  | Sill height. |
| `name` | string |  | Name. |
| `widthMm` | integer |  | Width. |
| `type` | `door` \| `window` \| `opening` |  | Kind. |
| `id` | uuid | yes | Opening id. (lowercase UUID) |
| `flipped` | boolean |  | Mirror along the wall. |
| `style` | `smooth` \| `panel2` \| `panel4` \| `glass` \| `sliding` \| `tiltTurn1` \| `tiltTurn2` \| `fixed` \| `balconyDoor` \| `balconyDoor2` |  | Look. Doors: `smooth`, `panel2`, `panel4`, `glass`, `sliding`; windows: `tiltTurn1`, `tiltTurn2`, `fixed`, `balconyDoor`, `balconyDoor2` (two-sash balcony door). Must suit the type (default: `smooth` door, `fixed` window). Sliding doors stay closed in walk mode. Tilt-and-turn windows and balcony doors open and tilt in the 3D view (`walk.toggle_door`) unless the opening is too small (inner width under about 200 mm or inner height under about 300 mm per sash); a two-sash style that is too narrow for two sashes gets one. A window that can open gets a `lever` handle when it is added or its style is changed without a `handle` argument; an explicit `none` stays. |
| `handle` | `lever` \| `knob` \| `bar` \| `none` |  | Handle on doors and openable windows (default `none`; a window that can open gets `lever` when the style is set and no handle is given). |
| `frameWidthMm` | integer |  | Frame width 20...150 mm (default 50). |
| `mullionCols` | integer |  | Vertical glazing bars 0...6 (glass door, windows, sliding door). |
| `mullionRows` | integer |  | Horizontal glazing bars 0...6. |
| `glass` | `clear` \| `frosted` \| `tinted` |  | Glass type (default `clear`). |

Plus the common arguments `dryRun`, `expectedRevision`, `expectedObjectRevisions` (see above).

**Result:** Mutating response.

**Undo:** One undo step named "Agent: update opening". `dryRun` creates none.

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND`, `WRITE_LOCKED`, `CONFLICT` (stale revisions), `LOCKED`, `OUT_OF_RANGE`, `BUSY`.

### `geometry.create_dimension`  (mutating)

Adds a dimension line between two points; the label shows the distance.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `levelId` | uuid |  | Level; default the active level. (lowercase UUID) |
| `offsetMm` | integer |  | Distance of the dimension line from the measured line (default 300). |
| `id` | uuid |  | Optional id. (lowercase UUID) |
| `a` | point `{x, y[, z]}` mm | yes | First point. Millimetres. |
| `b` | point `{x, y[, z]}` mm | yes | Second point. Millimetres. |

Plus the common arguments `dryRun`, `expectedRevision`, `expectedObjectRevisions` (see above).

**Result:** Mutating response plus `id`.

**Undo:** One undo step named "Agent: create dimension". `dryRun` creates none.

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND`, `WRITE_LOCKED`, `CONFLICT` (stale revisions), `LOCKED`, `OUT_OF_RANGE`, `BUSY`.

### `geometry.create_level`  (mutating)

Adds a storey. Elevation defaults to the top of the highest level.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `elevationMm` | integer |  | Floor height above the ground level. |
| `id` | uuid |  | Optional id. (lowercase UUID) |
| `name` | string | yes | Level name. |
| `heightMm` | integer |  | Storey height (default 2500). |

Plus the common arguments `dryRun`, `expectedRevision`, `expectedObjectRevisions` (see above).

**Result:** Mutating response plus `id`.

**Undo:** One undo step named "Agent: create level". `dryRun` creates none.

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND`, `WRITE_LOCKED`, `CONFLICT` (stale revisions), `LOCKED`, `OUT_OF_RANGE`, `BUSY`.

### `geometry.update_level`  (mutating)

Changes a level. At least one field besides `id`.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `id` | uuid | yes | Level. |
| `name` | string |  | New name. |
| `elevationMm` | integer |  | Floor elevation. |
| `heightMm` | integer |  | Level height. |
| `visible` | boolean |  | Visibility. |
| `locked` | boolean |  | Lock the level. |

Plus the common arguments `dryRun`, `expectedRevision`, `expectedObjectRevisions` (see above).

**Result:** Mutating response (`changes` has the updated level).

**Undo:** One undo step. `dryRun` creates none.

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND`, `WRITE_LOCKED`, `CONFLICT` (stale revisions), `LOCKED`, `OUT_OF_RANGE`, `BUSY`.

### `geometry.update_dimension`  (mutating)

Changes a dimension line. At least one field besides `id`.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `id` | uuid | yes | Dimension. |
| `a` | point {x,y} |  | Start point. |
| `b` | point {x,y} |  | End point. |
| `offsetMm` | integer |  | Offset of the line from the measured points. |

Plus the common arguments `dryRun`, `expectedRevision`, `expectedObjectRevisions` (see above).

**Result:** Mutating response (`changes` has the updated dimension).

**Undo:** One undo step. `dryRun` creates none.

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND`, `WRITE_LOCKED`, `CONFLICT` (stale revisions), `LOCKED`, `OUT_OF_RANGE`, `BUSY`.

### `geometry.create_room_from_walls`  (mutating)

Creates a room from the closed wall loop around a point (same detection as double click in the plan). The room is inset by half the wall thickness. Walls that do not enclose the point (open polygon) give `INVALID_ARGUMENT`. Not idempotent: calling it again creates a second room on the same walls, so before retrying after an unclear result check the rooms with `scene.query`.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `point` | point {x,y} | yes | A point inside the enclosed area, in mm. |
| `levelId` | uuid |  | Level; default the active level. |
| `name` | string |  | Room name; default "Room N". |
| `id` | uuid |  | Id for the new room. |

Plus the common arguments `dryRun`, `expectedRevision`, `expectedObjectRevisions` (see above).

**Result:** Mutating response plus `id` and `points` (the room outline).

**Undo:** One undo step. `dryRun` creates none.

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND`, `WRITE_LOCKED`, `CONFLICT` (stale revisions), `LOCKED`, `OUT_OF_RANGE`, `BUSY`.

### `geometry.measure_distance`  (read-only)

Shortest distance between two targets, each either {"id": uuid} (furniture, wall, room, opening, dimension, group) or a point {"x","y"}. Walls are measured by their outline, furniture by its rotated footprint. overlap=true (distance 0) when they touch or one contains the other.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `from` | object | yes | First target: {id} or {x,y}. |
| `to` | object | yes | Second target: {id} or {x,y}. |

**Result:** `{distanceMm, exactMm, overlap, from:{x,y}, to:{x,y}, fromLabel, toLabel}`; `from`/`to` are the closest points. Containment counts as overlap (distance 0).

**Undo:** No undo (read-only).

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND` (unknown ids).

### `geometry.dimension_chain`  (mutating)

Adds a dimension chain (Maßkette): one dimension between each pair of neighbouring points on a shared line, plus an optional total dimension from the first to the last point, drawn 400 mm further out. Give either `points` (+ `levelId`) or a `wallId`, not both. With `points`, the line runs through the first and the last point; the other points are always projected onto it (a sideways offset never enters a dimension), sorted along it, and points with the same projected position (rounded to whole mm) are an error. With `wallId`, the points lie on the visible wall face as the plan draws it (mitred corners): the end points are the face corners, so `side: outer` measures the outer size and `inner` the inner size (room 4000 x 3000 with 240 walls: 4240 / 3760; a free wall end is square, the total is the axis length), followed by both edges of every door/window/opening on that face; openings reaching beyond the face ends are clamped, openings outside it ignored. All lengths are whole millimetres: the distance of the stored points, rounded half away from zero (exactly the number the plan shows); on slanted walls a single part can deviate by 1 mm from the ideal value (e.g. 899 or 901 instead of 900). With only two points there is just one dimension and no separate total.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `levelId` | uuid |  | Level for `points`; default the active level. With `wallId` it must be the wall's level if given. (lowercase UUID) |
| `points` | array of point `{x, y}` mm |  | Chain points (at least 2, at most 1000). |
| `wallId` | uuid |  | Wall to dimension along one face. (lowercase UUID) |
| `side` | `auto` \| `outer` \| `inner` \| `left` \| `right` |  | Wall face (with `wallId`): `auto` (default) = outer face, else left; `left` / `right` are seen from the wall start to its end. `outer` / `inner` fail with `INVALID_ARGUMENT` when the outside cannot be determined (no closed wall loop or room around the wall). |
| `includeOpenings` | boolean |  | With `wallId`: split the chain at door/window/opening edges (default true). |
| `offsetMm` | integer |  | Distance of the dimension line from the measured line, default 500. With `wallId` it is the distance from the wall face (not negative); with `points` it is signed, positive = left of the first-to-last direction. |
| `includeTotal` | boolean |  | Add the total dimension (default true; skipped when the chain has a single dimension). The total's offset is `offsetMm` + 400 (same sign). |

Plus the common arguments `dryRun`, `expectedRevision`, `expectedObjectRevisions` (see above).

**Result:** Mutating response plus `ids` (parts in order, the total last), `dimensions` (`id`, `a`, `b`, `offsetMm`, `lengthMm` each), `partsMm` (lengths of the parts), `sumOfPartsMm`, `totalLengthMm` (first to last point), `totalId` (null without total) and, with `wallId`, `wallId`, `side` (`left` or `right`, the face used) and `outerSide` (true when that face is the building's outside). On axis-parallel lines `sumOfPartsMm` equals `totalLengthMm`; on slanted lines they can differ by rounding, and single parts can be off by 1 mm.

**Undo:** One undo step named "Agent: dimension chain" for the whole chain. `dryRun` creates none (the ids and numbers are still reported).

**Errors:** `INVALID_ARGUMENT` (neither/both of `points` and `wallId`, fewer than 2 points, identical points, `side`/`includeOpenings` with `points`, negative `offsetMm` with `wallId`, undeterminable `outer`/`inner`), `NOT_FOUND` (level or wall), `WRITE_LOCKED`, `CONFLICT` (stale revisions), `LOCKED`, `OUT_OF_RANGE`, `BUSY`.


## Catalog and products (`catalog.*`)

### `catalog.create_product`  (mutating)

Creates a product record (wish list entry or real purchase) with price, links and notes. Prices are integer cents.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `priceMinor` | integer |  | Price in minor currency units (cents). null removes it. |
| `linkTo` | uuid |  | Optionally link the new product to this furniture, group or definition. (lowercase UUID) |
| `notes` | string |  | Own notes. |
| `dimensions` | size `{width, depth, height}` mm |  | Product size. null removes it. Millimetres. |
| `weightGrams` | integer |  | Weight in grams. null removes it. |
| `custom` | object |  | Free key/value fields (string values). |
| `currency` | string |  | ISO currency code, default EUR. |
| `tags` | array of string |  | Tags. |
| `materialText` | string |  | Material description. |
| `category` | string |  | Free category, e.g. Sofa. |
| `variants` | array of string |  | Variant names. |
| `description` | string |  | Short description. |
| `articleNumber` | string |  | Article number. |
| `name` | string | yes | Product name. |
| `manufacturer` | string |  | Manufacturer. |
| `priceDate` | string |  | Date of the price, yyyy-MM-dd. null removes it. |
| `id` | uuid |  | Optional id. (lowercase UUID) |
| `links` | array of object |  | Shop or data sheet links (http/https). |
| `colorText` | string |  | Colour description. |
| `status` | `idea` \| `shortlisted` \| `ordered` \| `purchased` \| `returned` \| `owned` |  | Purchase status. |
| `model` | string |  | Model name. |

Plus the common arguments `dryRun`, `expectedRevision`, `expectedObjectRevisions` (see above).

**Result:** Mutating response plus `id`.

**Undo:** One undo step named "Agent: create product". `dryRun` creates none.

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND`, `WRITE_LOCKED`, `CONFLICT` (stale revisions), `LOCKED`, `OUT_OF_RANGE`, `BUSY`.

### `catalog.update_product`  (mutating)

Changes a product; only the given keys change. null clears priceMinor, priceDate, dimensions, weightGrams.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `priceMinor` | integer |  | Price in minor currency units (cents). null removes it. |
| `notes` | string |  | Own notes. |
| `dimensions` | size `{width, depth, height}` mm |  | Product size. null removes it. Millimetres. |
| `weightGrams` | integer |  | Weight in grams. null removes it. |
| `custom` | object |  | Free key/value fields (string values). |
| `currency` | string |  | ISO currency code, default EUR. |
| `tags` | array of string |  | Tags. |
| `materialText` | string |  | Material description. |
| `category` | string |  | Free category, e.g. Sofa. |
| `variants` | array of string |  | Variant names. |
| `description` | string |  | Short description. |
| `articleNumber` | string |  | Article number. |
| `name` | string |  | Product name. |
| `manufacturer` | string |  | Manufacturer. |
| `priceDate` | string |  | Date of the price, yyyy-MM-dd. null removes it. |
| `id` | uuid | yes | Product id. (lowercase UUID) |
| `links` | array of object |  | Shop or data sheet links (http/https). |
| `colorText` | string |  | Colour description. |
| `status` | `idea` \| `shortlisted` \| `ordered` \| `purchased` \| `returned` \| `owned` |  | Purchase status. |
| `model` | string |  | Model name. |

Plus the common arguments `dryRun`, `expectedRevision`, `expectedObjectRevisions` (see above).

**Result:** Mutating response.

**Undo:** One undo step named "Agent: update product". `dryRun` creates none.

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND`, `WRITE_LOCKED`, `CONFLICT` (stale revisions), `LOCKED`, `OUT_OF_RANGE`, `BUSY`.

### `catalog.search_products`  (read-only)

Searches the project's products (paginated). Filters: query (name substring), category, status.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `category` | string |  | Exact category (case-insensitive). |
| `status` | `idea` \| `shortlisted` \| `ordered` \| `purchased` \| `returned` \| `owned` |  | Purchase status. |
| `cursor` | string |  | `nextCursor` of the previous page. |
| `query` | string |  | Case-insensitive name substring. |
| `limit` | integer |  | Page size, default 50, maximum 500. |

**Result:** `{items:[product], total, nextCursor?}`

**Undo:** No undo (read-only).

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND` (unknown ids).

### `catalog.link_product`  (mutating)

Links a product to furniture, a group or a definition; productId null removes the link.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `objectId` | uuid | yes | Furniture, group or definition. (lowercase UUID) |
| `productId` | uuid |  | Product id, or null to unlink. (lowercase UUID) |

Plus the common arguments `dryRun`, `expectedRevision`, `expectedObjectRevisions` (see above).

**Result:** Mutating response plus `objectId`, `productId`.

**Undo:** One undo step named "Agent: link product". `dryRun` creates none.

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND`, `WRITE_LOCKED`, `CONFLICT` (stale revisions), `LOCKED`, `OUT_OF_RANGE`, `BUSY`.

### `catalog.list_builtin`  (read-only)

Lists the built-in furniture catalog (paginated) with key, name, category, tags and size. Use the key with catalog.insert_builtin.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `category` | `Living` \| `Bedroom` \| `Kitchen` \| `Bathroom` \| `Office` \| `Dining` \| `Decor` \| `Lighting` |  | Category. |
| `cursor` | string |  | `nextCursor` of the previous page. |
| `query` | string |  | Words that must all occur in name, key, category or tags. |
| `limit` | integer |  | Page size, default 50, maximum 500. |

**Result:** `{items:[{key, name, category, tags, size}], total, nextCursor?, categories[]}`; the virtual key `sofa.modular` comes first.

**Undo:** No undo (read-only).

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND` (unknown ids).

### `catalog.insert_builtin`  (mutating)

Places a built-in catalog piece: adds its definition to the project when needed and creates an instance. Key `sofa.modular` inserts the complete modular sofa as one group (position = centre of module Corner A).

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `rotationDeg` | number |  | Rotation in degrees, counter-clockwise from above (default 0). |
| `key` | string | yes | Catalog key from catalog.list_builtin. |
| `levelId` | uuid |  | Level; default the active level. (lowercase UUID) |
| `position` | point `{x, y[, z]}` mm | yes | Footprint centre; z = height above the floor (default 0). Millimetres; z optional. |
| `name` | string |  | Instance name (default: catalog name). |

Plus the common arguments `dryRun`, `expectedRevision`, `expectedObjectRevisions` (see above).

**Result:** Mutating response plus `id`, `definitionId`, `key`; for `sofa.modular`: `id`=`groupId`, `memberIds` (7 modules).

**Undo:** One undo step named "Agent: insert builtin". `dryRun` creates none.

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND`, `WRITE_LOCKED`, `CONFLICT` (stale revisions), `LOCKED`, `OUT_OF_RANGE`, `BUSY`.

### `catalog.import_model`  (action; changes the project)

Imports a USD/USDZ model like File > Import 3D Model...: copies the file into the project package (`assets/`), measures it and creates a furniture design (category Imported, one mesh part). With `place` it also puts one instance there. Needs the Roomsmith app, write access and a saved project.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `path` | string | yes | Absolute path of a `.usdz`, `.usd`, `.usda` or `.usdc` file. |
| `name` | string |  | Design name (default: file name without extension). |
| `place` | `{position, levelId?}` |  | Also place an instance: `position` is the footprint centre in mm (z optional, default 0), `levelId` defaults to the active level. |

**Result:** Mutating response plus `designId`, `name`, `assetId`, `size{width, depth, height}` in mm (width = X, depth = Z, height = Y of the model), and `instanceId` (also as `id`) when `place` was given; `warning` when the largest side is outside 20...20 000 mm (the file may use other units). No `dryRun`, `expectedRevision` or `expectedObjectRevisions`; not usable inside `app.batch`.

**Undo:** One undo step named "Agent: import model". A model file that was newly copied is removed again when the edit fails.

**Errors:** `INVALID_ARGUMENT` (not absolute, wrong extension, unreadable model, no geometry, size out of range), `NOT_FOUND` (file or level), `NO_FILE` (project has no file yet: call `project.save_as` first), `CONFLICT`, `OUT_OF_RANGE`, `WRITE_LOCKED`, `INTERNAL` (the file could not be copied into the package), `UNSUPPORTED`.


## Furniture designs, states and configurations (`furniture.*`)

### `furniture.create_definition`  (mutating)

Creates a reusable furniture design from primitive parts. Coordinates are local: origin = centre of the footprint on the floor, +X right, +Y back, +Z up. A component's `position` is the centre of its box. Optional states define alternative poses (e.g. folded/unfolded). If the project already has an identical own design (same name, size, parts, states; ids ignored) and no `id` or `forceNew` is given, that design is returned with `reused: true` and nothing is added. Other designs with the same name are listed in `similar`: to swap a placed model use `furniture.replace_definition` instead of leaving the old design behind.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `size` | size `{width, depth, height}` mm | yes | Nominal overall size. Millimetres. |
| `forceNew` | boolean |  | Add the design even if an identical one exists (default false). |
| `id` | uuid |  | Optional id. (lowercase UUID) |
| `category` | string |  | Category (default Custom). |
| `name` | string | yes | Design name. |
| `tags` | array of string |  | Tags. |
| `defaultState` | string |  | Name of the state new instances start in. |
| `components` | array of object | yes | Parts. |
| `states` | array of object |  | Named poses. |

Plus the common arguments `dryRun`, `expectedRevision`, `expectedObjectRevisions` (see above).

**Result:** Mutating response plus `id`, `componentIds {name: id}`, `stateIds {name: id}`; `reused: true` when an identical design was returned (nothing added); `similar [{id, name, builtin, placedCount}]` and `hint` when other designs have the same name.

**Undo:** One undo step named "Agent: create definition". `dryRun` creates none.

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND`, `WRITE_LOCKED`, `CONFLICT` (stale revisions), `LOCKED`, `OUT_OF_RANGE`, `BUSY`.

### `furniture.list_definitions`  (read-only)

Lists furniture designs of the project (paginated), including those inserted from the built-in catalog. `placedCount` is the number of pieces placed from a design; 0 means unused (see `furniture.prune_unused_definitions`).

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `unused` | boolean |  | Only designs no piece is placed from (true) or only used ones (false). |
| `limit` | integer |  | Page size, default 50, maximum 500. |
| `category` | string |  | Category (case-insensitive). |
| `cursor` | string |  | `nextCursor` of the previous page. |
| `builtin` | boolean |  | Only built-in (true) or only own (false) designs. |
| `query` | string |  | Case-insensitive name substring. |

**Result:** `{items:[definition rows], total, nextCursor?}`

**Undo:** No undo (read-only).

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND` (unknown ids).

### `furniture.create_instance`  (mutating)

Places a furniture design on a level. `position` is the footprint centre; z is the height of the underside above the floor. `allowsOverlap` exempts the piece from collision warnings (it also never blocks while dragging).

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `rotationDeg` | number |  | Degrees counter-clockwise from above (default 0). |
| `size` | size `{width, depth, height}` mm |  | Custom exact size (default: design size). Millimetres. |
| `levelId` | uuid |  | Level; default the active level. (lowercase UUID) |
| `id` | uuid |  | Optional id. (lowercase UUID) |
| `position` | point `{x, y[, z]}` mm | yes | Footprint centre. Millimetres; z optional. |
| `definitionId` | uuid | yes | Design from furniture.list_definitions. (lowercase UUID) |
| `name` | string |  | Instance name (default: design name). |
| `options` | object |  | Option picks {"<group name or id>": "<choice name or id>" or null}. |
| `allowsOverlap` | boolean |  | true: the piece may overlap furniture, walls and openings without a collision warning (default false). Flat floor pieces (z <= 0, height <= 150 mm) never collide anyway. |

Plus the common arguments `dryRun`, `expectedRevision`, `expectedObjectRevisions` (see above).

**Result:** Mutating response plus `id`, `ids`.

**Undo:** One undo step named "Agent: create instance". `dryRun` creates none.

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND`, `WRITE_LOCKED`, `CONFLICT` (stale revisions), `LOCKED`, `OUT_OF_RANGE`, `BUSY`.

### `furniture.update_instance`  (mutating)

Changes one placed piece: name, exact position, rotation, custom size (null = design size), visibility, whether it may overlap (no collision warnings), per-component materials or the chosen options (colour, front, handle).

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `rotationDeg` | number |  | Absolute rotation in degrees. |
| `size` | size `{width, depth, height}` mm |  | Custom size, or null for the design size. Millimetres. |
| `position` | point `{x, y[, z]}` mm |  | New footprint centre (z optional, keeps the current height). Millimetres; z optional. |
| `id` | uuid | yes | Furniture id. (lowercase UUID) |
| `name` | string |  | New name. |
| `materials` | object |  | {"<component name or id>": material id/name, or null to restore the design's material}. Wins over an option colour given in the same call. |
| `options` | object |  | {"<group name or id>": "<choice name or id>" or null for the default}. Applied before `materials`. |
| `visible` | boolean |  | Visibility. |
| `allowsOverlap` | boolean |  | true: the piece may overlap furniture, walls and openings without a collision warning; false restores the warnings. |

Plus the common arguments `dryRun`, `expectedRevision`, `expectedObjectRevisions` (see above).

**Result:** Mutating response.

**Undo:** One undo step named "Agent: update instance". `dryRun` creates none.

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND`, `WRITE_LOCKED`, `CONFLICT` (stale revisions), `LOCKED`, `OUT_OF_RANGE`, `BUSY`.

### `furniture.define_state`  (mutating)

Adds or replaces (same name) a named pose of a design, e.g. "unfolded". Instances switch with furniture.activate_state. An optional transition sets duration and easing of the animation into this state.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `size` | size `{width, depth, height}` mm |  | Overall size in this state (default: derived). Millimetres. |
| `transition` | object |  | Animation into this state. |
| `poses` | object |  | Pose overrides keyed by component name or id: {"<component>": {position?, rotation? (degrees x/y/z), size?, visible?}}. |
| `name` | string | yes | State name. |
| `definitionId` | uuid | yes | Design. (lowercase UUID) |
| `makeDefault` | boolean |  | New instances start in this state. |

Plus the common arguments `dryRun`, `expectedRevision`, `expectedObjectRevisions` (see above).

**Result:** Mutating response plus `stateId`.

**Undo:** One undo step named "Agent: define state". `dryRun` creates none.

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND`, `WRITE_LOCKED`, `CONFLICT` (stale revisions), `LOCKED`, `OUT_OF_RANGE`, `BUSY`.

### `furniture.delete_state`  (mutating)

Deletes a state of a furniture design together with the animations from and to it. If it was the default state, the first remaining state becomes the default; instances in it return to the default.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `definitionId` | uuid | yes | Furniture design. |
| `state` | string \| uuid | yes | State name or id. |

Plus the common arguments `dryRun`, `expectedRevision`, `expectedObjectRevisions` (see above).

**Result:** Mutating response plus `deletedStateId` and `defaultStateId`.

**Undo:** One undo step. `dryRun` creates none.

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND`, `WRITE_LOCKED`, `CONFLICT` (stale revisions), `LOCKED`, `OUT_OF_RANGE`, `BUSY`.

### `furniture.define_option_group`  (mutating)

Adds or replaces (same name) an option group of a design, e.g. "Colour" or "Door": a set of choices, each changing the material and/or visibility of named parts. Placed pieces pick one choice per group (`furniture.set_options`). Options never change size or pose (a different width is a separate design); `states` stay for movement such as open/closed. Replacing a group by name keeps the group id and the ids of choices with the same name, so picks survive.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `definitionId` | uuid | yes | Design. |
| `name` | string | yes | Group name, unique within the design. |
| `choices` | array | yes | Choices (1 to 24); each `{name, effects?, id?}`. `effects` = {"<component name or id>": {material?: material id/name, visible?: bool}}; `visible: false` hides the part, `true` never shows a part the design or its state hides. |
| `defaultChoice` | string \| uuid |  | Choice used by pieces that picked nothing (default: the first). |

Example (wardrobe with a colour and a door group):

```json
{"definitionId": "<id>", "name": "Colour",
 "choices": [{"name": "Oak", "effects": {"body": {"material": "Oak"}}},
             {"name": "Black", "effects": {"body": {"material": "Black"}}}]}
```

Plus the common arguments `dryRun`, `expectedRevision`, `expectedObjectRevisions` (see above).

**Result:** Mutating response plus `groupId` and `choiceIds` (choice name to id).

**Undo:** One undo step. `dryRun` creates none.

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND`, `WRITE_LOCKED`, `CONFLICT` (stale revisions), `LOCKED`, `OUT_OF_RANGE`, `BUSY`.

### `furniture.delete_option_group`  (mutating)

Deletes an option group (by name or id). Placed pieces forget their pick in it and show the design's own look for those parts.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `definitionId` | uuid | yes | Design. |
| `group` | string \| uuid | yes | Group name or id. |

Plus the common arguments `dryRun`, `expectedRevision`, `expectedObjectRevisions` (see above).

**Result:** Mutating response plus `deletedGroupId`.

**Undo:** One undo step. `dryRun` creates none.

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND`, `WRITE_LOCKED`, `CONFLICT` (stale revisions), `LOCKED`, `OUT_OF_RANGE`, `BUSY`.

### `furniture.set_options`  (mutating)

Chooses options on placed furniture. Group and choice by name or id; null returns a group to its default. Clears the pieces' own material overrides of the parts a chosen group colours. All or nothing across the pieces.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `ids` | array of uuid | yes | Furniture ids. |
| `options` | object | yes | {"<group name or id>": "<choice name or id>" or null}; at least one group. |

Example: `{"ids": ["<id>"], "options": {"Colour": "Black", "Door": "Without"}}`

Plus the common arguments `dryRun`, `expectedRevision`, `expectedObjectRevisions` (see above).

**Result:** Mutating response plus `ids`.

**Undo:** One undo step. `dryRun` creates none.

**Errors:** `INVALID_ARGUMENT` (empty `options`), `NOT_FOUND` (unknown group or choice, or one of another design), `WRITE_LOCKED`, `CONFLICT` (stale revisions), `LOCKED`, `OUT_OF_RANGE`, `BUSY`.

Detail output: `scene.get_object` of a piece returns `availableOptions` (groups with `choices`, `selectedChoiceId`, `selectedChoice`) and `options` (group name to chosen choice name); of a design `optionGroups`.

### `furniture.replace_definition`  (mutating)

Swaps the model of placed furniture: every piece placed from design `fromId` (or only `instanceIds`) switches to design `toId` and keeps its position, rotation, size and name. Its state, option choices and colours carry over to the state, option group and part of the same name (case ignored); anything without a match falls back to the default state or the design's own look; configurations of groups the pieces belong to follow. Then the old design is deleted when nothing uses it any more (not if built-in or linked to a product), unless `removeOld` is false.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `fromId` | uuid | yes | Design to replace. |
| `toId` | uuid | yes | Design to use instead. |
| `instanceIds` | array of uuid |  | Only switch these pieces (placed from `fromId`); default all pieces of `fromId`. |
| `removeOld` | boolean |  | Delete the old design afterwards when unused (default true). |

Plus the common arguments `dryRun`, `expectedRevision`, `expectedObjectRevisions` (see above).

**Result:** Mutating response plus `ids` (switched pieces), `replaced` (count), `removedDefinitions [{id}]`, `keptDefinitionIds`.

**Undo:** One undo step named "Agent: replace definition". `dryRun` changes nothing.

**Errors:** `INVALID_ARGUMENT` (same design, a piece not placed from `fromId`, not a design), `NOT_FOUND`, `LOCKED` (a locked piece fails the whole call), `WRITE_LOCKED`, `CONFLICT` (stale revisions), `OUT_OF_RANGE`, `BUSY`.

### `furniture.delete_definitions`  (mutating)

Deletes furniture designs that no piece is placed from. All or nothing: a design with placed pieces or a built-in one fails the call and nothing changes; the error names every blocker. Placed furniture is never touched; a product linked to a deleted design stays (unlinked).

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `ids` | array of uuid | yes | Design ids from `furniture.list_definitions` (own designs only). |

Plus the common arguments `dryRun`, `expectedRevision`, `expectedObjectRevisions` (see above).

**Result:** Mutating response plus `deleted` (ids) and `count`.

**Undo:** One undo step named "Agent: delete definitions". `dryRun` deletes none.

**Errors:** `INVALID_ARGUMENT` (design still used, with `details.referenced`; built-in design; not a design), `NOT_FOUND`, `WRITE_LOCKED`, `LOCKED`, `OUT_OF_RANGE`, `BUSY`.

### `furniture.prune_unused_definitions`  (mutating, `dryRun` defaults to true)

Deletes every own furniture design that no piece is placed from and no product is linked to (built-in designs stay). `dryRun` defaults to TRUE: it only lists what would go; pass `dryRun: false` to delete.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `dryRun` | boolean |  | List only (default true). Pass false to delete. |

**Result:** Dry run: `{wouldRemove [{id, name}], count, dryRun: true, committed: false, revision, unusedLinkedKept}`. Real run: mutating response plus `removed [{id, name}]`, `count`, `unusedLinkedKept` (unused designs a product points at; they stay).

**Undo:** One undo step named "Agent: prune unused definitions".

**Errors:** `WRITE_LOCKED` (real run only), `CONFLICT`, `BUSY`.

### `furniture.set_animation`  (mutating)

Sets the animation into a state (replaces the one with the same from/to).

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `definitionId` | uuid | yes | Furniture design. |
| `from` | string \| uuid \| null |  | Start state; null or missing = from any state. |
| `to` | string \| uuid | yes | Target state. |
| `durationMs` | integer |  | 0...60000. |
| `easing` | string |  | Easing name. |

Plus the common arguments `dryRun`, `expectedRevision`, `expectedObjectRevisions` (see above).

**Result:** Mutating response plus `trackId`.

**Undo:** One undo step. `dryRun` creates none.

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND`, `WRITE_LOCKED`, `CONFLICT` (stale revisions), `LOCKED`, `OUT_OF_RANGE`, `BUSY`.

### `furniture.activate_state`  (mutating)

Switches placed furniture to a named state of its design. `state` null returns to the base pose. All pieces must have a state of that name.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `ids` | array of uuid | yes | Furniture ids. |
| `state` | any |  | State name or id; null = base pose. |

Plus the common arguments `dryRun`, `expectedRevision`, `expectedObjectRevisions` (see above).

**Result:** Mutating response plus `ids`.

**Undo:** One undo step named "Agent: activate state". `dryRun` creates none.

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND`, `WRITE_LOCKED`, `CONFLICT` (stale revisions), `LOCKED`, `OUT_OF_RANGE`, `BUSY`.

### `furniture.save_configuration`  (mutating)

Stores the current arrangement of a furniture group (positions, rotations, visibility, states of all members) as a named configuration and marks it active. An existing configuration of the same name is overwritten.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `name` | string | yes | Configuration name. |
| `groupId` | uuid | yes | Group. (lowercase UUID) |

Plus the common arguments `dryRun`, `expectedRevision`, `expectedObjectRevisions` (see above).

**Result:** Mutating response plus `configurationId`, `groupId`.

**Undo:** One undo step named "Agent: save configuration". `dryRun` creates none.

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND`, `WRITE_LOCKED`, `CONFLICT` (stale revisions), `LOCKED`, `OUT_OF_RANGE`, `BUSY`.

### `furniture.activate_configuration`  (mutating)

Rearranges a group's members to a saved configuration (by name or id).

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `configuration` | string | yes | Configuration name or id. |
| `groupId` | uuid | yes | Group. (lowercase UUID) |

Plus the common arguments `dryRun`, `expectedRevision`, `expectedObjectRevisions` (see above).

**Result:** Mutating response plus `configurationId`, `groupId`, `name`.

**Undo:** One undo step named "Agent: activate configuration". `dryRun` creates none.

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND`, `WRITE_LOCKED`, `CONFLICT` (stale revisions), `LOCKED`, `OUT_OF_RANGE`, `BUSY`.

### `furniture.update_configuration`  (mutating)

Renames a saved configuration of a group and/or duplicates it. `name` alone renames; `duplicate: true` copies it (named "<name> copy", or `name` if given); the original keeps its name. Names must be unique in the group.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `groupId` | uuid | yes | Group. |
| `configuration` | string \| uuid | yes | Configuration name or id. |
| `name` | string |  | New name. |
| `duplicate` | boolean |  | Copy instead of rename. |

Plus the common arguments `dryRun`, `expectedRevision`, `expectedObjectRevisions` (see above).

**Result:** Mutating response plus `groupId`, `configurationId` and `name` of the changed or new configuration.

**Undo:** One undo step. `dryRun` creates none.

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND`, `WRITE_LOCKED`, `CONFLICT` (stale revisions), `LOCKED`, `OUT_OF_RANGE`, `BUSY`.

### `furniture.delete_configuration`  (mutating)

Deletes a saved configuration of a group (by name or id). The current arrangement stays as it is.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `groupId` | uuid | yes | Group. (lowercase UUID) |
| `configuration` | string | yes | Configuration name or id. |

Plus the common arguments `dryRun`, `expectedRevision`, `expectedObjectRevisions` (see above).

**Result:** Mutating response plus `configurationId`, `groupId`.

**Undo:** One undo step named "Agent: delete configuration". `dryRun` creates none.

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND`, `WRITE_LOCKED`, `CONFLICT` (stale revisions), `LOCKED`, `OUT_OF_RANGE`, `BUSY`.

### `furniture.list_configurations`  (read-only)

Lists the saved configurations of one group, or of all groups when groupId is omitted.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `groupId` | uuid |  | Only this group. (lowercase UUID) |

**Result:** `{groups:[{groupId, name, rev, levelId, activeConfigurationId, configurations:[{id, name, active, memberCount, visibleCount}]}], revision}`

**Undo:** No undo (read-only).

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND` (unknown ids).


### `furniture.update_definition`  (mutating)

Changes an existing furniture design without breaking its instances: name, category, nominal size, tags, and its parts (change, add, remove). Parts keep their ids, so placed instances, their material overrides and states stay valid. Removing a part also removes it from states and animation keyframes and drops instance overrides of that part. Instances with their own size (set by `scene.resize` or a drag) keep it exactly; instances without one follow a new nominal size, and the result counts them as `followingInstances`.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `id` | uuid | yes | Design id (lowercase UUID). |
| `name` | string |  | New name. |
| `category` | string |  | New category. |
| `size` | size `{width, depth, height}` mm |  | New nominal overall size. |
| `tags` | array of string |  | Replaces all tags. |
| `updateComponents` | array |  | `{component (id or name), name?, shape?, position?, size?, rotation?, pivot? (null = centre), material? (null removes), visible?}`; only given keys change. |
| `addComponents` | array |  | Same shape as the `components` of `furniture.create_definition`. |
| `removeComponents` | array of string |  | Part ids or names; at least one part must remain. |

Plus the common arguments `dryRun`, `expectedRevision`, `expectedObjectRevisions` (see above).

**Result:** Mutating response plus `id`, `componentCount`, `componentIds` (name to id), `removedComponents`, `instanceCount`, `followingInstances` (instances without their own size that changed with the nominal size).

**Undo:** One undo step named "Agent: update definition". `dryRun` creates none.

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND`, `WRITE_LOCKED`, `CONFLICT` (stale revisions), `LOCKED`, `OUT_OF_RANGE`, `BUSY`.

### `furniture.create_from_template`  (mutating)

Creates a furniture design from a parametric template (the same generators as the furniture builder). The parts are plain primitives that `furniture.update_definition` can refine. Built-in catalogue designs are inserted with `catalog.insert_builtin`.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `template` | string | yes | `cabinet`, `table`, `shelf`, `sofa` or `box`. |
| `name` | string | yes | Design name. |
| `size` | size `{width, depth, height}` mm | yes | Overall size. |
| `shelves` | integer |  | cabinet: 0...20 (default 2). |
| `doors` | integer |  | cabinet: 0...6 and at most width / 150, but always at least 1 allowed (default 2); more is `INVALID_ARGUMENT`. |
| `plinth` | integer |  | cabinet: plinth height mm, 0...1000 (default 60). |
| `legInset` | integer |  | table: leg inset mm, 0...1000 (default 50). |
| `topThickness` | integer |  | table: 1...1000 mm (default 30). |
| `boards` | integer |  | shelf: 1...30 (default 4). |
| `armWidth` | integer |  | sofa: 0...2000 mm (default 150). |
| `seatHeight` | integer |  | sofa: 1...2000 mm (default 420). |
| `material` | string |  | Material id or name for all parts. |

Plus the common arguments `dryRun`, `expectedRevision`, `expectedObjectRevisions` (see above).

**Result:** Mutating response plus `id`, `template`, `size`, `componentCount`, `componentIds`.

**Undo:** One undo step named "Agent: create from template". `dryRun` creates none.

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND`, `WRITE_LOCKED`, `CONFLICT` (stale revisions), `LOCKED`, `OUT_OF_RANGE`, `BUSY`.

## Library (`library.*`)

The global furniture library lives next to the built-in catalogue and outside any project; all projects share it. Sections: `own`, `planned`, `ai` (the app's Examples section shows five built-in pieces; the full built-in catalogue is `catalog.list_builtin`). Purchase `status` is one of `idea`, `shortlisted`, `ordered`, `purchased`, `returned`, `owned`. Only `library.place` changes the open project. The tools that change the library are not part of the project history and have no undo, and they need write access (`WRITE_LOCKED`). A library row is `{id, section, name, description, size, materialNames, tags, status, rev, categoryId}`.

Entries added through `library.add_from_object` or `library.duplicate` show a "New" badge in the app sidebar until the user clicks them; so do objects an agent adds to the open project (until selected). The badge is a display hint only: it is not part of any tool result and is not saved.

### `library.list`  (read-only)

Lists the library, paginated.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `query` | string |  | Words that must all occur in name, description, section, status, tags or materials. |
| `section` | `own` \| `planned` \| `ai` |  | Only this section. |
| `status` | purchase status |  | Only entries with this status. |
| `categoryId` | uuid \| `"unsorted"` |  | Only entries of this category, or the string `unsorted` for entries without one. |
| `limit`, `cursor` | integer, string |  | Paging as for the other list tools. |

**Result:** `{items:[row], total, nextCursor?, revision, sectionCounts{own, planned, ai}, categories:[{id, name, order, entries}], warning?}`. Each row carries `categoryId` (`null`: Unsorted); `categories` lists all categories in display order.

**Errors:** `INVALID_ARGUMENT`.

### `library.get`  (read-only)

One library entry with its builder recipe, photo file names and the designs inside.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `id` | uuid | yes | Library entry id from `library.list`. |

**Result:** the row plus `definitionId`, `photoAssetNames`, `createdAt`, `spec` (the parametric recipe, or null when the entry was saved from placed furniture or its recipe was dropped), `definitions[{name, size}]` and `pieces` (number of placed pieces stored).

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND`.

### `library.add_from_object`  (action)

Saves furniture of the active project as a new library entry. Designs, materials, products and models travel along; the project is not changed.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `ids` | array of uuid |  | Furniture instance ids (or group ids). |
| `definitionId` | uuid |  | A design on its own instead of placed furniture. Not with `ids`. |
| `section` | `own` \| `planned` \| `ai` |  | Target section (default `own`). |
| `name` | string |  | Entry name (default the furniture's name). |
| `description` | string |  | Free text. |
| `tags` | array of string |  | Search tags. |
| `status` | purchase status |  | Planned entries default to `idea`. |
| `categoryId` | uuid |  | Category from `library.list` (default: Unsorted). |

**Result:** `{entry}` (a library row).

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND`, `WRITE_LOCKED`, `INTERNAL`.

### `library.update`  (action)

Changes name, description, tags, status (`null` clears it), section or category (`categoryId`, `null` moves it to Unsorted) of an entry. With `fromObjectId` the stored furniture is replaced by that piece of the active project; its builder recipe is dropped (so it can no longer be improved by `library.create_from_photo`) and the picture is rendered anew. Without it the stored furniture stays.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `id` | uuid | yes | Library entry id. |
| `name` | string |  | New name. |
| `description` | string |  | New description. |
| `tags` | array of string |  | Replaces the tags. |
| `status` | purchase status |  | New status, or `null` to clear. |
| `section` | `own` \| `planned` \| `ai` |  | Move to this section. |
| `categoryId` | uuid \| null |  | Move to this category from `library.list`, or `null` for Unsorted. |
| `fromObjectId` | uuid |  | Furniture instance or group of the active project that replaces the stored furniture. |

At least one field besides `id` is required.

**Result:** `{entry}`.

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND`, `WRITE_LOCKED`, `INTERNAL`.

### `library.create_category`  (action)

Creates a category (a collapsible group of My Furniture) at the end of the list. The name must be unique, ignoring case.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `name` | string | yes | Category name. |

**Result:** `{category}` (`{id, name, order, entries}`; `entries` is 0 for a new category).

**Errors:** `INVALID_ARGUMENT`, `WRITE_LOCKED`, `INTERNAL`.

### `library.update_category`  (action)

Renames a category and/or moves it in the list.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `id` | uuid | yes | Category id from `library.list`. |
| `name` | string |  | New name. |
| `position` | integer |  | New place, 0 is first (clamped to the end). |

At least one of `name`, `position` is required.

**Result:** `{categories}` in display order.

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND`, `WRITE_LOCKED`, `INTERNAL`.

### `library.delete_category`  (action)

Deletes a category. Its entries move to `moveTo` or, without it, to Unsorted; no entry is deleted. Cannot be undone.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `id` | uuid | yes | Category id. |
| `moveTo` | uuid |  | Another existing category that takes over the entries. |

**Result:** `{deleted, name, categories}`.

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND`, `WRITE_LOCKED`, `INTERNAL`.

### `library.duplicate`  (action)

Copies an entry as "<name> 2" (next free number) in the same category, with its own furniture file and thumbnail, revision 1.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `id` | uuid | yes | Library entry id. |

**Result:** `{entry}`.

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND`, `WRITE_LOCKED`, `INTERNAL`.

### `library.delete`  (action)

Deletes an entry with its stored furniture, thumbnail and unused photos. Projects that used the furniture keep their copies. Cannot be undone.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `id` | uuid | yes | Library entry id. |

**Result:** `{deleted, name}`.

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND`, `WRITE_LOCKED`, `INTERNAL`.

### `library.place`  (mutating)

Places an entry into the active project: designs, materials, products and models are added (reused when equal) and the furniture is created with new ids, its middle at `position`. The library stays unchanged. Entries with models or textures need a saved project (`INVALID_ARGUMENT` otherwise).

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `id` | uuid | yes | Library entry id from `library.list`. |
| `position` | `{x, y}` | yes | Where the middle of the furniture goes (plan coordinates, mm). |
| `levelId` | uuid |  | Level; default the active level. |

Plus the common arguments `dryRun`, `expectedRevision`, `expectedObjectRevisions` (see above).

**Result:** Mutating response plus `entryId` and `newIds`.

**Undo:** One undo step named "Agent: place". `dryRun` creates none.

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND`, `WRITE_LOCKED`, `CONFLICT` (stale revisions), `LOCKED`, `OUT_OF_RANGE`, `BUSY`, `INTERNAL`.

### `library.thumbnail`  (async)

Returns the rendered PNG thumbnail of an entry, inline as an image and/or written to `path`. The default size is rendered once per entry revision and cached; other sizes are rendered each time and not cached. Rendering needs the Roomsmith window (`UNSUPPORTED` otherwise) unless the cached image exists. Not read-only: a new render writes the thumbnail cache of the global library (also while agents are locked); `path` additionally needs write access (`WRITE_LOCKED`).

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `id` | uuid | yes | Library entry id. |
| `size` | integer |  | Pixel size 32...1024 (default 384, the cached size). |
| `inline` | boolean |  | Return the image in the answer. Default true without `path`, false with it. Limited to 4 MiB. |
| `path` | string |  | Absolute target file ending in `.png`, outside the project package. Needs write access. |
| `overwrite` | boolean |  | Replace an existing file at `path` (default false). |

**Result:** `{id, rev, cached, bytes, image?, path?, written?}`; `image` is `{mimeType, base64}`, `path` and `written` appear when `path` was given. `cached` is false when the image was rendered for this call.

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND`, `OUT_OF_RANGE` (inline image over 4 MiB), `WRITE_LOCKED`, `UNSUPPORTED`, `INTERNAL`.

### `library.create_from_photo`  (mutating, async)

Creates parametric furniture from one or more photos and stores it in the **AI** section of the library. The photo is analysed on this Mac with the on-device Vision framework (nothing leaves the machine): the closest builder template (`cabinet`, `table`, `shelf`, `sofa`, `box`) is chosen from what the photo shows and the hint, the foreground silhouette gives proportions, and the dominant colours become a material. A photo cannot tell real sizes, so at least one dimension is required. This is an approximation from five templates, not a 3D reconstruction. Needs the Roomsmith app (`UNSUPPORTED` otherwise) and write access, because it changes the global library.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `dimensions` | object `{width?, depth?, height?}` mm | yes | At least one member; the others are estimated from the photo's proportions. Each 1...100 000 mm. |
| `imagePath` | string |  | Absolute path of a photo (JPEG, PNG, HEIC, GIF, TIFF, WebP or BMP), at most 30 MB. |
| `imagePaths` | array of string |  | More photos of the same piece (the first is the front view). With `imagePath` and `imageBase64` at most 6 photos in total. |
| `imageBase64` | string |  | The photo as Base64 (a `data:` URL is accepted). Alternative to a path; at most about 10 MB of image data. |
| `hint` | string |  | What it is, German or English ("three-seat sofa with arm rests", "Schrank mit zwei Türen"). Settles the template when the photo is ambiguous. |
| `name` | string |  | Entry name (default: the hint, else the template name). |
| `improveEntryId` | uuid |  | Improve this library entry instead of creating a new one: sizes and material follow the new photo and dimensions, the template changes only when the new photo is clearly another kind (otherwise it is suggested in `notes`). Parameter values follow the new photo unless they are listed in `keepFields`. An entry without a builder recipe (its parts were edited by hand in the furniture builder, or it was saved from placed furniture) cannot be improved and returns `INVALID_ARGUMENT`, so hand-edited parts are never overwritten. |
| `keepFields` | array of string |  | With `improveEntryId`: parameters that stay as they are (`width`, `depth`, `height`, `shelves`, `doors`, `plinth`, `legInset`, `topThickness`, `boards`, `armWidth`, `seatHeight`, `material`). A dimension given in `dimensions` of the same call wins over `keepFields`. |

At least one of `imagePath`, `imagePaths`, `imageBase64` is required.

**Result:** `{entry, improved, suggestion}`; `entry` is a library row (`id`, `section`, `name`, `description`, `size`, `materialNames`, `tags`, `rev`, `status`). With `improveEntryId` the result also has `templateChanged`, `changedFields` and `keptFields`. `suggestion` is `{template, spec, size, estimated, material, recognised, ambiguous, alternatives, notes}`: the chosen template and its parameters, the dimensions that were estimated rather than given (`estimated`), the material name (or null), whether the template was recognised (`false` = fallback to `box`), whether another template scored close (`alternatives` lists them), and plain-language notes about limits of the photo.

**Undo:** Not part of the project history (the library is global). Improving an entry bumps its `rev`.

**Errors:** `INVALID_ARGUMENT` (no photo, unsupported or unreadable image, too many photos, no or out-of-range dimensions, unknown `keepFields`, a path that is not a regular file, an entry without builder recipe), `NOT_FOUND` (file or `improveEntryId`), `WRITE_LOCKED`, `UNSUPPORTED` (no app: the analysis needs Vision), `INTERNAL`.

## Background images (`background.*`)

A background is a scanned plan under a level. Pixel positions are whole image pixels from the top-left corner (x right, y down); a calibration point cannot lie between pixels. World position of a pixel is `origin + (px * mmPerPixel, -py * mmPerPixel)` (Y is north). The scale is `mmPerPixel = realLengthMm / pixel distance(pixelA, pixelB)`, exact in floating point; the stored origin is whole millimetres (at most 0.5 mm off).

### `background.add`  (mutating)

Adds a background image under a level and calibrates it. The image comes from `path` (absolute file, copied into the package's `assets/` folder, so the project must have been saved once; the same image is stored only once) or `assetId` (existing image asset). Calibration is required.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `path` | string |  | Absolute path of a PNG, JPEG, TIFF, HEIC, GIF or BMP. Exactly one of `path`, `assetId`. |
| `assetId` | uuid |  | Existing image or background asset. |
| `levelId` | uuid |  | Level; default the active level. |
| `pixelA`, `pixelB` | point `{x, y}` pixels |  | Calibration pixels (inside the image, different). |
| `realLengthMm` | integer |  | Real distance between them, 1...100000 mm (outside: `OUT_OF_RANGE`). |
| `mmPerPixel` | number |  | Scale instead of the pixel pair (not combinable with it), 0.001...100 (outside: `OUT_OF_RANGE`). Stored as a synthetic pixel pair (it may lie outside the image): exact when up to 1000 px give whole mm, otherwise less than 1e-5 relative error over the whole range (e.g. 25.4/300 for a 300 dpi scan). |
| `originMm` | point `{x, y}` mm |  | World position of the top-left pixel (default 0,0). |
| `opacity` | number |  | 0...1, default 0.5. |
| `visible` | boolean |  | Default true. |

Plus the common arguments `dryRun`, `expectedRevision`, `expectedObjectRevisions` (see above).

**Result:** Mutating response plus the background row: `id`, `assetId`, `mmPerPixel`, `originMm`, `widthPx`, `heightPx`, `extentMm {minX, maxX, minY, maxY}`.

**Undo:** One undo step named "Agent: add background". `dryRun` creates none.

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND`, `WRITE_LOCKED`, `CONFLICT` (stale revisions), `LOCKED`, `OUT_OF_RANGE`, `BUSY`. `dryRun` (also of an `app.batch` containing this step) copies nothing into the package. If the commit fails after the copy, the unreferenced file stays in `assets/`.

### `background.calibrate`  (mutating)

Sets the scale from two pixels and the real distance between them. The world position of `pixelA` stays where it is (or moves to `worldA`), so the plan scales around that point.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `id` | uuid | yes | Background id. |
| `pixelA`, `pixelB` | point `{x, y}` pixels | yes | Calibration pixels, different, inside the image. |
| `realLengthMm` | integer | yes | Real distance, 1...100000 mm (outside: `OUT_OF_RANGE`). |
| `worldA` | point `{x, y}` mm |  | New world position of `pixelA`. |

Plus the common arguments `dryRun`, `expectedRevision`, `expectedObjectRevisions` (see above).

**Result:** Mutating response plus the background row, `previousMmPerPixel` and `measuredDistanceMm` (distance of the two pixels in the plan, equals `realLengthMm`).

**Undo:** One undo step named "Agent: calibrate background". `dryRun` creates none.

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND`, `WRITE_LOCKED`, `CONFLICT` (stale revisions), `LOCKED`, `OUT_OF_RANGE`, `BUSY`.

### `background.update`  (mutating)

Changes opacity, visibility, the position of the top-left pixel or the level. The scale is changed with `background.calibrate`. Only given keys change.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `id` | uuid | yes | Background id. |
| `opacity` | number |  | 0...1. |
| `visible` | boolean |  | Show or hide. |
| `originMm` | point `{x, y}` mm |  | World position of the top-left pixel. |
| `levelId` | uuid |  | Move to this level. |

Plus the common arguments `dryRun`, `expectedRevision`, `expectedObjectRevisions` (see above).

**Result:** Mutating response plus the background row.

**Undo:** One undo step named "Agent: update background". `dryRun` creates none.

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND`, `WRITE_LOCKED`, `CONFLICT` (stale revisions), `LOCKED`, `OUT_OF_RANGE`, `BUSY`.

## Materials (`material.*`)

Own materials with a unique (case-insensitive) name. Use the name or id wherever a material is expected. Image textures come from the app's asset import; without one, a material can get a procedural `pattern` generated from `color` and `color2`. Built-in presets (`material.list_presets`) set finish, pattern and gloss in one step.

### `material.create`  (mutating)

Creates a material.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `name` | string | yes | Unique name. |
| `id` | uuid |  | Optional id. |
| `color` | string | yes | Hex colour `#RRGGBB`. |
| `roughness` | number |  | 0 = mirror ... 1 = matte (default 0.7). |
| `metallic` | number |  | 0...1 (default 0). |
| `opacity` | number |  | 0 = invisible ... 1 = solid (default 1). |
| `textureTileMm` | integer |  | Real-world size of one texture tile, 1...100000 mm (default 1000). |
| `finish` | `matte` \| `satin` \| `brushed` \| `polished` |  | Surface finish (default `matte`). |
| `pattern` | `none` \| `stripes` \| `grid` \| `tiles` \| `wood` \| `fabric` \| `leather` |  | Procedural pattern generated from the colours (default `none`; an imported image texture wins over it). |
| `color2` | string |  | Second pattern colour `#RRGGBB` (stripes, grid lines, tile joints, wood grain); default a darker shade of `color`. |
| `patternSizeMm` | integer |  | Size of one pattern cell (stripe pair, tile, plank, thread), 1...100000 mm (default 100). |
| `patternAngleDeg` | number |  | Rotation of the pattern in degrees. |
| `groutMm` | integer |  | Joint width of tiles, grid lines and planks, 0...100 mm (default 3). |
| `clearcoat` | number |  | Clear lacquer layer 0...1 (default 0). |
| `specular` | number |  | Highlight strength 0...1 (default 0.5). |

Plus the common arguments `dryRun`, `expectedRevision`, `expectedObjectRevisions` (see above).

**Result:** Mutating response plus `id`, `ids`.

**Undo:** One undo step named "Agent: create material". `dryRun` creates none.

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND`, `WRITE_LOCKED`, `CONFLICT` (stale revisions), `LOCKED`, `OUT_OF_RANGE`, `BUSY`.

### `material.update`  (mutating)

Changes a material; everything that uses it follows. Only given keys change.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `id` | uuid | yes | Material id. |
| `name` | string |  | New unique name. |
| `color`, `roughness`, `metallic`, `opacity`, `textureTileMm` | as in `material.create` |  | New values. |
| `finish`, `pattern`, `color2`, `patternSizeMm`, `patternAngleDeg`, `groutMm`, `clearcoat`, `specular` | as in `material.create` |  | New values. `color2: null` or `""` removes the second colour (back to the derived darker shade). |

At least one key besides `id` is required.

Plus the common arguments `dryRun`, `expectedRevision`, `expectedObjectRevisions` (see above).

**Result:** Mutating response plus the material row `{id, name, color, roughness, metallic, opacity, textureTileMm, rev, preset, finish, pattern, color2, patternSizeMm, patternAngleDeg, groutMm, clearcoat, specular}` (`preset` and `color2` are null when unset).

**Undo:** One undo step named "Agent: update material". `dryRun` creates none.

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND`, `WRITE_LOCKED`, `CONFLICT` (stale revisions), `LOCKED`, `OUT_OF_RANGE`, `BUSY`.

### `material.apply_preset`  (mutating)

Applies a built-in preset to a material: roughness, finish, pattern and gloss are replaced; the colour stays unless the preset has one. An imported image texture is removed.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `id` | uuid | yes | Material id. |
| `preset` | string | yes | Preset id or name (case-insensitive), see `material.list_presets`. |

Plus the common arguments `dryRun`, `expectedRevision`, `expectedObjectRevisions` (see above).

**Result:** Mutating response plus the material row (as for `material.update`).

**Undo:** One undo step named "Agent: apply preset". `dryRun` creates none.

**Errors:** `INVALID_ARGUMENT` (unknown preset), `NOT_FOUND`, `WRITE_LOCKED`, `CONFLICT` (stale revisions), `LOCKED`, `OUT_OF_RANGE`, `BUSY`.

### `material.list_presets`  (read-only)

Lists the built-in material presets.

Arguments: none.

**Result:** `{presets:[{id, name, group, color, finish, pattern, roughness, metallic, opacity}]}`; `group` is one of `paint`, `wallpaper`, `tiles`, `wood`, `fabric`, `leather`, `metal`, `glass`, `plastic`; `color` is null when the preset keeps the material's colour.

**Errors:** none specific.

## Light (`light.*`)

Sun, sky and lamps. All of it is document state with undo (`lighting.*` in `project.md`, lamps per furniture design, `lightOn` per placed piece; see `FILE_FORMAT.md`). North is given in degrees counter-clockwise from plan +Y (0 = north is +Y, east is +X). Time is local solar time. At most 8 lamps render at once (the strongest win); lamps cast no shadows and their brightness is an estimate (see "Known limits" in `STATUS.md`).

### `light.get`  (read-only)

Sun, sky and lamps in one answer.

Arguments: none.

**Result:** `{lighting{northDeg, dayOfYear, timeMinutes, time, latitudeDeg, mood, shadows, exposure, sun{azimuthDeg, elevationDeg, strength, castsShadows}}, designs[{id, name, lights[emitter]}], pieces[{id, name, definitionId, lightOn}], activeLamps, skipped, maxActive, moods}`. An emitter is `{id, name, kind, positionMm, kelvin, lumens, rangeMm, color?}` plus `yawDeg`, `pitchDeg`, `coneDeg` for spots. `moods` lists `daylight`, `evening`, `night`, `overcast`.

**Errors:** none specific.

### `light.set`  (mutating)

Changes sun and sky; only the given keys change. At least one of the keys is required.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `northDeg` | number |  | Direction of north in the plan, -360...360. |
| `dayOfYear` | integer |  | 1...366 (21 June = 172). |
| `timeMinutes` | integer |  | Minutes after midnight, 0...1439. |
| `latitudeDeg` | number |  | -66...66, positive = north. |
| `mood` | `daylight` \| `evening` \| `night` \| `overcast` |  | Atmosphere preset. |
| `applyMoodTime` | boolean |  | With `mood`: also set the time to the mood's suggested time (daylight 13:00, evening 19:30, night 23:30, overcast 12:00). Default false. |
| `shadows` | boolean |  | Sun shadows on or off. |
| `exposure` | number |  | Exposure in EV stops, -3...3. |

Plus the common arguments `dryRun`, `expectedRevision`, `expectedObjectRevisions` (see above).

**Result:** Mutating response plus `lighting` (as in `light.get`).

**Undo:** One undo step named "Agent: set". `dryRun` creates none.

**Errors:** `INVALID_ARGUMENT` (out of range, no key given), `WRITE_LOCKED`, `CONFLICT` (stale revisions), `BUSY`.

### `light.set_emitter`  (mutating)

Adds a lamp to a furniture design, or changes one (`emitterId`). A design has at most 8 lamps. All placed pieces of the design follow.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `definitionId` | uuid | yes | Furniture design id. |
| `emitterId` | uuid |  | Existing lamp to change; omit to add a new one. |
| `name` | string |  | Lamp name. |
| `kind` | `point` \| `spot` |  | Lamp kind. |
| `positionMm` | `{x, y, z}` |  | Position in the design's space in mm (origin at the footprint centre on the floor). A new lamp defaults to the centre, 100 mm below the design's top. |
| `yawDeg` | number |  | Spot aim, degrees counter-clockwise from +X. |
| `pitchDeg` | number |  | Spot aim, -90...90 (-90 = straight down). |
| `coneDeg` | number |  | Full cone angle of a spot, 10...150. |
| `kelvin` | integer |  | Colour temperature, 1500...12000. |
| `color` | string |  | Hex colour `#RRGGBB`; overrides `kelvin`. `null` goes back to `kelvin`. |
| `lumens` | integer |  | Brightness, 1...100000 (a 60 W bulb is about 800). |
| `rangeMm` | integer |  | Reach in mm, 200...30000. |

Plus the common arguments `dryRun`, `expectedRevision`, `expectedObjectRevisions` (see above).

**Result:** Mutating response plus `id` (the lamp), `ids` (the design) and `emitter` (as in `light.get`).

**Undo:** One undo step named "Agent: set emitter". `dryRun` creates none.

**Errors:** `INVALID_ARGUMENT` (not a design, out of range, more than 8 lamps), `NOT_FOUND` (design, lamp), `WRITE_LOCKED`, `CONFLICT` (stale revisions), `BUSY`.

### `light.remove_emitter`  (mutating)

Removes a lamp from a furniture design.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `definitionId` | uuid | yes | Furniture design id. |
| `emitterId` | uuid | yes | Lamp id. |

Plus the common arguments `dryRun`, `expectedRevision`, `expectedObjectRevisions` (see above).

**Result:** Mutating response plus `ids` (the design).

**Undo:** One undo step named "Agent: remove emitter". `dryRun` creates none.

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND`, `WRITE_LOCKED`, `CONFLICT` (stale revisions), `BUSY`.

### `light.toggle`  (mutating)

Switches the lamps of a placed piece on or off. Works on locked pieces too. Without `on` the state flips.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `id` | uuid | yes | Placed furniture id. |
| `on` | boolean |  | Target state; omit to flip. |

Plus the common arguments `dryRun`, `expectedRevision`, `expectedObjectRevisions` (see above).

**Result:** Mutating response plus `id`, `ids` and `lightOn`.

**Undo:** One undo step named "Agent: toggle". `dryRun` creates none.

**Errors:** `INVALID_ARGUMENT` (not a placed piece, or its design has no lamps), `NOT_FOUND`, `WRITE_LOCKED`, `CONFLICT` (stale revisions), `BUSY`.

## Camera (`camera.*`)

### `camera.get_state`  (read-only)

Current 3D camera and the saved views.

Arguments: none.

**Result:** `{camera:{mode, target, distanceMm, yawDeg, pitchDeg, fovDeg}, savedCameras[], revision}`

**Undo:** No undo (read-only).

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND` (unknown ids).

### `camera.set_state`  (mutating)

Moves the 3D camera (partial update). Not recorded in undo history.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `mode` | `orbit` \| `firstPerson` \| `top` \| `free` |  | Camera mode. |
| `target` | point `{x, y[, z]}` mm |  | Orbit: point looked at. First person and free: eye position. Millimetres; z optional. |
| `distanceMm` | integer |  | Orbit distance in mm (10...1000000). |
| `pitchDeg` | number |  | Pitch in degrees, negative looks down (-90...90). |
| `fovDeg` | number |  | Field of view in degrees (10...120). |
| `yawDeg` | number |  | Heading in degrees, 0 = north (+Y), counter-clockwise. |

Plus the common arguments `dryRun`, `expectedRevision`, `expectedObjectRevisions` (see above).

**Result:** Mutating response plus `camera`. `committed` follows the normal rules but the change is not an undo step.

**Undo:** Not recorded in undo history (viewing the model is not an edit).

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND`, `WRITE_LOCKED`, `CONFLICT` (stale revisions), `LOCKED`, `OUT_OF_RANGE`, `BUSY`.

### `camera.save`  (mutating)

Saves the current camera (or the given camera keys on top of it) as a named view.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `mode` | `orbit` \| `firstPerson` \| `top` \| `free` |  | Camera mode. |
| `target` | point `{x, y[, z]}` mm |  | Orbit: point looked at. First person and free: eye position. Millimetres; z optional. |
| `name` | string | yes | Name of the saved view. |
| `distanceMm` | integer |  | Orbit distance in mm (10...1000000). |
| `pitchDeg` | number |  | Pitch in degrees, negative looks down (-90...90). |
| `yawDeg` | number |  | Heading in degrees, 0 = north (+Y), counter-clockwise. |
| `fovDeg` | number |  | Field of view in degrees (10...120). |

Plus the common arguments `dryRun`, `expectedRevision`, `expectedObjectRevisions` (see above).

**Result:** Mutating response plus `id`, `camera`.

**Undo:** One undo step named "Agent: save". `dryRun` creates none.

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND`, `WRITE_LOCKED`, `CONFLICT` (stale revisions), `LOCKED`, `OUT_OF_RANGE`, `BUSY`.


### `camera.apply`  (mutating)

Moves the 3D camera to a saved view. Give exactly one of `id` or `name`. Not recorded in the undo history.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `id` | uuid |  | Saved view id. |
| `name` | string |  | Saved view name (case-insensitive; must be unique, else `INVALID_ARGUMENT` listing the ids). |

**Result:** `{camera{...}}` plus the common write fields.

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND`, `WRITE_LOCKED`.

### `camera.preset`  (action)

Moves the 3D camera to a preset like the view buttons and stores it in the project without an undo step. Needs write access and the Roomsmith window (`UNSUPPORTED` otherwise).

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `preset` | `aerial` \| `reset` \| `top` \| `frame` | yes | `aerial` overview, `reset` reset view, `top` view from above fitted to the whole content, `frame` frame content. |
| `ids` | array of uuid |  | Only with `frame`: objects to frame (default the whole scene). |

**Result:** `{preset, camera{...}}`

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND`, `UNSUPPORTED`, `WRITE_LOCKED`.

## View (`view.*`)

Window and view state the user sees. It is not part of the project file: no revision, no undo step. Both tools need the Roomsmith window (`UNSUPPORTED` otherwise).

### `view.get`  (read-only)

Layout (`split`/`plan`/`scene`), arrangement (`sideBySide`/`stacked`), divider, sidebar tab and panel visibility, 3D display options, active level and the plan viewport.

Arguments: none.

**Result:** `{layout, arrangement, splitFraction, sidebarTab, sidebar, inspector, statusBar, sceneControls, showCeilings, showLamps, onlyActiveLevel, wallOpacity, detach3D, activeLevelId, planViewport{center{x, y}, mmPerPoint}|null}` (`planViewport` is null while the plan is not shown; X east, Y north, millimetres).

**Errors:** `UNSUPPORTED`.

### `view.set`  (action)

Partial update of the view state. Everything is validated before anything changes. Needs write access. The plan viewport is applied by the plan editor on its next redraw and only while it is shown.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `layout` | `split` \| `plan` \| `scene` |  | Which editors are shown. |
| `arrangement` | `sideBySide` \| `stacked` |  | Plan and 3D side by side or stacked. |
| `splitFraction` | number |  | Divider position 0.1...0.9 in the (new) arrangement. |
| `activeLevelId` | uuid |  | Level to show (must exist). |
| `planViewport` | `{center{x, y}, mmPerPoint}` |  | Centre in mm and zoom 0.25...500 mm per view point. Not with `planFit`. If the same call also switches `layout` so the plan appears, send `planViewport` in a second call. |
| `planFit` | `all` \| `selection` |  | Fit the level or the selection into the plan view. |
| `sidebarTab` | `levels` \| `objects` \| `catalog` |  | Sidebar page. |
| `sidebar`, `inspector`, `statusBar`, `sceneControls` | boolean |  | Panel visibility; `sceneControls` is the floating 3D bar. |
| `wallOpacity` | number |  | 3D wall opacity 0...1. |
| `onlyActiveLevel` | boolean |  | 3D view shows only the active level. |
| `showCeilings` | boolean |  | 3D view shows ceilings. |
| `showLamps` | boolean |  | 3D view shows lamp furniture: designs with lights, category `Lighting`, or lamp/light in name or tags (default true). false hides only the pieces; their light stays on and unchanged. Hidden pieces cannot be picked in 3D, do not block in walk mode and are no obstacle when dragging furniture in 3D. |
| `detach3D` | boolean |  | `true` opens the 3D view in its own window (like View > Open 3D in Separate Window; the main window then shows the plan only), `false` docks it back; the main window then shows plan + 3D again unless `layout: plan` is given in the same call. `true` cannot be combined with `layout` other than `plan`; setting `layout` `split` or `scene` while detached docks the window. The result already reports the state after the window change. |

At least one key is required (`INVALID_ARGUMENT`).

**Result:** the new state like `view.get`.

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND`, `OUT_OF_RANGE`, `UNSUPPORTED`, `WRITE_LOCKED`.

## Walk mode (`walk.*`)

The first-person camera of the 3D view (body height, field of view, collision, controller) is view state of the user: it is not part of the project file, has no revision and no undo step. The tools need the Roomsmith window (`UNSUPPORTED` otherwise); `walk.measure` works on the project alone. Defaults: body height 1750 mm, eye at 93.6% of the body height, standard FOV 60 degrees, speeds 0.8 / 1.4 / 2.5 m/s, collision on.

### `walk.get`  (read-only)

Walk settings and live state.

Arguments: none.

**Result:** the settings (`bodyHeightMm`, `eyeHeightOverrideMm`, `fovMode{mode, fovDeg?}`, `screenHeightMm`, `viewingDistanceMm`, `speedSlowMps`, `speedNormalMps`, `speedFastMps`, `accelerationMps2`, `crouchEyeFactor`, `headBob`, `collision`, `mouseSensitivity`, `invertY`, `controllerDeadzone`, `controllerSensitivity`, `bodyRadiusMm`, `showScale`) plus `eyeHeightMm` (current, with crouching and head bob), `baseEyeHeightMm`, `active` (3D camera is in first person), `speedMps`, `fovDeg` (in use), `autoScreenHeightMm` (read from the display, or null) and `openDoors` (opening ids).

**Errors:** `UNSUPPORTED`.

### `walk.set`  (action)

Partial update of the walk settings, validated as a whole before anything changes. Needs write access. At least one setting is required. `eyeHeightOverrideMm` and `screenHeightMm` accept `null` to go back to automatic.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `bodyHeightMm` | number |  | Body height 1000...2300. |
| `eyeHeightOverrideMm` | number or null |  | Eye height above the floor 600...2200; null = from body height. |
| `fovMode` | `{mode: "standard", fovDeg: 10...120}` or `{mode: "calibrated"}` |  | Calibrated: the view subtends the same angle as the physical screen at `viewingDistanceMm` (1:1). |
| `screenHeightMm` | number or null |  | Physical picture height of the screen 50...3000; null = read from the display. |
| `viewingDistanceMm` | number |  | Eye-to-screen distance for the calibrated FOV, 200...3000. |
| `speedSlowMps`, `speedNormalMps`, `speedFastMps` | number |  | Slow (Alt) and normal 0.1...10, fast (Shift) 0.1...15. |
| `accelerationMps2` | number |  | Acceleration and braking, 0.2...30. |
| `crouchEyeFactor` | number |  | Eye height share while crouching, 0.3...1. |
| `headBob` | boolean |  | Walking bobs the view. |
| `collision` | boolean |  | Walls, closed doors, windows and furniture block. |
| `mouseSensitivity` | number |  | Degrees per mouse point, 0.02...1. |
| `invertY` | boolean |  | Invert vertical look. |
| `controllerDeadzone` | number |  | Stick deadzone, 0...0.9. |
| `controllerSensitivity` | number |  | Stick look speed in degrees per second, 10...400. |
| `bodyRadiusMm` | number |  | Collision radius, 50...600. |
| `showScale` | boolean |  | Show the 1 m scale stick. |

**Result:** the new state like `walk.get`.

**Errors:** `INVALID_ARGUMENT` (wrong type, null where not allowed), `OUT_OF_RANGE` (a value outside its range; nothing was changed), `WRITE_LOCKED`, `UNSUPPORTED`.

### `walk.toggle_door`  (action)

Opens or closes a door, window or balcony door in the 3D view (animated; the project is untouched). `mode` `turn` (default) swings the door leaf or window sash open to the swing side, `tilt` (windows and balcony doors that can open) tips the sash in at the top by about 10 degrees. A two-sash window turns both sashes; tilting moves only the sash with the handle. Asking for the other mode while one is open closes it first and then opens the other; asking for the same mode again toggles it shut. Doors and turned balcony doors can be walked through when the sill is at most 100 mm; windows and tilted sashes stay solid; closed ones block. Needs write access and the live 3D view. Fixed windows, plain openings and windows too small to open are refused.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `openingId` | uuid | yes | A door, window or balcony door. |
| `open` | boolean |  | `true` opens, `false` closes; omit to toggle. |
| `mode` | `turn` \| `tilt` |  | How to open (default `turn`). Doors only turn. |

**Result:** `{openingId, open, mode}`; `mode` is the mode it is heading to (`closed` when it ends up shut), `open` is `mode != closed`. `walk.get` lists the open ones as `openOpenings: [{id, mode}]` (doors are also in `openDoors`). `render.scene_image` and the presenter draw the openings in the pose the live view shows.

**Errors:** `INVALID_ARGUMENT` (plain opening, fixed or too small window, tilt on a door, unknown `mode`), `NOT_FOUND`, `WRITE_LOCKED`, `UNSUPPORTED`.

### `walk.measure`  (read-only)

Measures from the walker's point of view, in mm.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `kind` | `eye_above_surface` \| `window_sill` \| `door_clear` \| `gap` | yes | What to measure. |
| `ids` | array of uuid | yes | `eye_above_surface`: one furniture piece (eye height minus its top, e.g. a worktop). `window_sill`: one window (parapet height). `door_clear`: one door or opening (clear width and height inside the frame). `gap`: two furniture pieces (shortest distance between the two footprints). |

**Result:** `{kind, valueMm, detail}`; `door_clear` adds `clearWidthMm` and `clearHeightMm`. `eye_above_surface` uses the eye height of the current walk settings (the default when there is no window).

**Errors:** `INVALID_ARGUMENT` (wrong kind or id count, wrong object type), `NOT_FOUND`.

## Workspace (`workspace.*`)

The Roomsmith window can hold several projects as tabs, and show two of them in a compare split. All other tools act on the **active** project. These tools need the Roomsmith window (`UNSUPPORTED` otherwise). Tab ids and project ids are both accepted wherever a `projectId` is expected. Moving furniture between projects is `scene.transfer_objects`.

### `workspace.list`  (read-only)

Lists the open projects.

Arguments: none.

**Result:** `{projects:[{id, projectId, name, path, dirty, active, inCompare}]}`; `path` is null for an unsaved project, `dirty` means unsaved changes, `inCompare` means shown in the compare split.

**Errors:** `UNSUPPORTED`.

### `workspace.activate`  (action)

Makes an open project the active one: from the next call on, all tools act on it and the editor shows its tab. Calls that are already waiting keep their project. `app.subscribe_changes` stays bound to the project that was active when it was called.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `projectId` | uuid | yes | Tab id or project id from `workspace.list`. |

**Result:** the list like `workspace.list`.

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND`, `UNSUPPORTED`.

### `workspace.open`  (action)

Opens a `.roomsmith` package in a new tab and makes it active. An empty unchanged tab is reused; a file that is already open is just activated. Without `path` a new untitled project opens. No dialog is shown. Needs write access.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `path` | string |  | Absolute path of an existing `.roomsmith` package folder. Omit for a new untitled project. |

**Result:** the list like `workspace.list` plus `opened` (the tab id).

**Errors:** `INVALID_ARGUMENT` (not a package), `NOT_FOUND`, `WRITE_LOCKED`, `UNSUPPORTED`.

### `workspace.close`  (action)

Closes an open project (tab). Closing the last tab leaves a new untitled project. Needs write access.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `projectId` | uuid | yes | Tab id or project id from `workspace.list`. |
| `discard` | boolean |  | Drop unsaved changes (default false). |

**Result:** the list like `workspace.list`.

**Errors:** `CONFLICT` (unsaved changes and no `discard`), `INVALID_ARGUMENT`, `NOT_FOUND`, `WRITE_LOCKED`, `UNSUPPORTED`.

### `workspace.compare`  (read-only)

Compares two open projects: total floor area, rooms with area, furniture count and wall length of each, plus the differences (b minus a).

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `projectA` | uuid |  | Tab id or project id; default the active project. |
| `projectB` | uuid |  | Tab id or project id; default the only other open project (required when more than two are open). |
| `show` | boolean |  | Also show both in the compare split (default false). This changes the window but not a project, and therefore needs write access (`WRITE_LOCKED`); without `show` the call only reads. |
| `arrangement` | `sideBySide` \| `stacked` |  | Split direction when shown. |

**Result:** `{a, b, difference, note}`; `a` and `b` are `{name, totalAreaM2, rooms[{name, level, areaM2}], furnitureCount, wallLengthMm}`, `difference` is `{totalAreaM2, furnitureCount, wallLengthMm}`.

**Errors:** `INVALID_ARGUMENT` (no active project, `projectB` missing or equal to `projectA`), `NOT_FOUND`, `UNSUPPORTED`, `WRITE_LOCKED` (with `show` only).

## Render (`render.*`)

Images as PNG. Without `path` the image comes back inline: the result carries `image{mimeType, base64}`, which the MCP bridge turns into an MCP image content block (it is removed from `structuredContent`). Inline images are limited to 4 MiB (`OUT_OF_RANGE`; use a smaller size or `path`). With `path` the file rules of the export tools apply (absolute, `.png`, existing folder, no overwrite without `overwrite: true`, write access); the image is then only inline when `inline: true`. No undo step, no revision change.

### `render.scene_image`  (action)

Renders the 3D scene with the user's 3D display options. Needs the Roomsmith window (`UNSUPPORTED` otherwise). Without `camera` it shows what the user sees, else the project camera; `camera` overrides single keys of that. `preset` frames the picture like the 3D view buttons but fitted to `width` x `height`, starting from the camera the user sees (`aerial` and `top` keep its heading; `frame` keeps it except in first person, where it turns towards the content; `reset` turns to the mode's reset heading, except at the aerial tilt, where it re-fits the aerial view and keeps the heading); the live view and the stored camera stay unchanged.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `width`, `height` | integer |  | Pixels 16...8192 (default 1280 x 800). |
| `dark` | boolean |  | Dark appearance. |
| `camera` | object |  | Camera keys as in `camera.set_state`; at least one. Not with `preset`. |
| `preset` | `aerial` \| `top` \| `reset` \| `frame` |  | Frame the picture like a view button, fitted to its size. |
| `ids` | uuid[] |  | Only with `preset: frame`: objects to frame (default the whole scene); unknown ids give `NOT_FOUND`. |
| `path`, `inline`, `overwrite` | |  | See above. |

**Result:** `{width, height, bytes, image?, path?, written?}`

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND`, `OUT_OF_RANGE`, `UNSUPPORTED`, `WRITE_LOCKED`, `INTERNAL`.

### `render.plan_image`  (action)

Renders the floor plan of a level as PNG, laid out exactly like `export.plan` (true to scale on a paper sheet; a plan that does not fit gives the same `OUT_OF_RANGE` with `details`). Works without the window.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `levelId` | uuid |  | Level; default the active level. |
| `paper` | `A4` ... `Letter` |  | Default A3. |
| `orientation` | `auto` \| `landscape` \| `portrait` |  | Default auto. |
| `scale` | integer or `"fit"` |  | 1:N (default 100) or `fit`. |
| `dpi` | number |  | 36...600 (default 100); lowered automatically for huge sheets. |
| `path`, `inline`, `overwrite` | |  | See above. |

**Result:** `{levelId, level, scale, paper, landscape, dpi, width, height, bytes, image?, path?, written?}`

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND`, `OUT_OF_RANGE`, `WRITE_LOCKED`, `INTERNAL`.

## Export (`export.*`)

Both tools write files on disk and need write access (`WRITE_LOCKED` otherwise). Path rules: absolute path, extension matches the format, the parent folder exists, no overwriting unless `overwrite: true` (`INVALID_ARGUMENT`, `details.existing`), never inside a `.roomsmith` package. Files are written atomically. No undo step, no revision change.

### `export.plan`  (action)

Exports the plan as SVG or PDF with the same layout as the Export dialog. A plan that does not fit the paper at the scale is not shrunk: `OUT_OF_RANGE` with `details` (`requiredWidthMm`, `requiredHeightMm`, `suggestedPaper`).

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `format` | `svg` \| `pdf` | yes | For PNG use `render.plan_image` (`png` gives `INVALID_ARGUMENT`). |
| `path` | string | yes | Absolute target file path. |
| `levelId` | uuid |  | Level; default the active level. |
| `allLevels` | boolean |  | Every level, one file each (`name-<level>.ext` next to `path`). Not with `levelId`. |
| `paper` | `A4` \| `A3` \| `A2` \| `A1` \| `A0` \| `Letter` |  | Default A3. |
| `orientation` | `auto` \| `landscape` \| `portrait` |  | Default auto. |
| `scale` | integer or `"fit"` |  | N for 1:N (default 100), or `fit` for the largest scale that fits. |
| `overwrite` | boolean |  | Replace existing files. |

**Result:** `{files[{path, levelId, level, scale, paper, landscape, pageWidthMm, pageHeightMm}], format, path, scale, pageWidthMm, pageHeightMm}` (the last four repeat the first file)

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND`, `OUT_OF_RANGE`, `WRITE_LOCKED`.

### `export.obj`  (action)

Writes the 3D model as Wavefront OBJ plus a `.mtl` with the same base name (the OBJ references it).

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `path` | string | yes | Absolute path ending in `.obj`. |
| `levelId` | uuid |  | Level; default the active level. |
| `allVisible` | boolean |  | All visible levels instead of one. Not with `levelId`. |
| `overwrite` | boolean |  | Replace existing `.obj` and `.mtl`. |

**Result:** `{path, mtlPath, levelId, allVisible}`

**Errors:** `INVALID_ARGUMENT`, `NOT_FOUND`, `WRITE_LOCKED`.

## Reports (`report.*`)

All three are read-only and work without write access. `format` is `json` (default), `csv` (RFC 4180, header row) or `markdown`
(table). For `csv` and `markdown` the result is `{format, text}`. Areas and volumes are exact decimal strings (m² with 2, m³ with 3
decimals, rounded half away from zero), computed from integer millimetres, so they are never off by float rounding.

### `report.rooms`  (read-only)

Room report: floor area, perimeter, clear height, volume and wall areas (gross and net) per room, with level and project totals.
Floor area is the plain polygon area (no living-area factors). Wall areas count only walls along room edges, capped at the level
height, with openings subtracted for the net value.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `format` | string |  | `json`, `csv` or `markdown`. |
| `levelId` | uuid |  | Only this level; default all levels. |

**Result (json):** `{projectName, levels[{id, name, clearHeightMm, rooms[{id, name, floorAreaM2, perimeterM, clearHeightMm, volumeM3, wallAreaGrossM2, wallAreaNetM2, wallMatchedLengthMm, unmatchedEdgeLengthMm, overlappingWallLengthMm, furnitureCount}], floorAreaM2, volumeM3, wallAreaGrossM2, wallAreaNetM2, furnitureInRooms, furnitureOutsideRooms, furnitureTotal}], totals{floorAreaM2, volumeM3, wallAreaGrossM2, wallAreaNetM2, roomsWithoutWalls, furnitureTotal}, notes}`. `volumeM3` and `clearHeightMm` are `null` when the level has no clear height. Per room, `wallAreaGrossM2` and `wallAreaNetM2` are `null` when no wall lies along the room edges; level and project sums then count that room as 0 (see `roomsWithoutWalls`). With `levelId`, `totals` cover only that level.

**Errors:** `INVALID_ARGUMENT` (unknown format), `NOT_FOUND` (unknown level).

### `report.bom`  (read-only)

Bill of materials: furniture grouped by definition, effective size, product and material, with unit and total prices per currency;
wall count, total length and one-face area; openings by kind and size.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `format` | string |  | `json`, `csv` or `markdown`. |

**Result (json):** `{projectName, furniture[{definitionId, name, count, widthMm, depthMm, heightMm, material, productId, currency, unitPrice, totalPrice}], furnitureCount, totals[{currency, pieces, total}], unpricedCount, walls{count, totalLengthM, areaM2}, openings[{kind, widthMm, heightMm, count}], instancesWithoutDefinition}`. Prices are decimal strings. `material` (when empty), `productId`, `currency`, `unitPrice` and `totalPrice` can be `null`; pieces without a price count in `unpricedCount`.

**Errors:** `INVALID_ARGUMENT` (unknown format).

### `report.clearances`  (read-only)

Clearance check: furniture closer than the walkway width to other furniture or to walls, furniture in the approach strip in front
of a door, and furniture inside a door's swing (quarter circle). Distances in mm. Fix findings with `scene.move_objects`.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `format` | string |  | `json`, `csv` or `markdown`. |
| `levelId` | uuid |  | Only this level; default all levels. |
| `minWalkwayMm` | number |  | Minimum gap between pieces and between a piece and a wall (0...100000, default 600). |
| `doorApproachMm` | number |  | Free depth in front of doors (0...100000, default 900). |
| `checkDoorSwing` | boolean |  | Report furniture inside the door swing (default true). |

**Result (json):** `{count, rules{minWalkwayMm, doorApproachMm, checkDoorSwing}, findings[{kind, levelId, instanceId, otherId, otherKind, distanceMm, limitMm, overlaps, position{x, y}}]}`. `overlaps` is true when the two outlines intersect (distance 0).

**Errors:** `INVALID_ARGUMENT` (unknown format, rule out of range), `NOT_FOUND` (unknown level).

## History (`history.*`)

### `history.undo`  (mutating)

Undo the last change(s) of the project. This also undoes changes made by the user, not only by agents. Needs write access.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `steps` | integer |  | How many steps (1...50, default 1). |

**Result:** `{committed, performed, names[], changes[], revision, undoName, redoName}`

**Undo:** Is itself the undo. It also undoes edits the user made.

**Errors:** `WRITE_LOCKED`, `BUSY` (the user is dragging an affected object).

### `history.redo`  (mutating)

Redo what was undone. Needs write access.

| Argument | Type | Required | Meaning |
|---|---|---|---|
| `steps` | integer |  | How many steps (1...50, default 1). |

**Result:** `{committed, performed, names[], changes[], revision, undoName, redoName}`

**Undo:** Redoes what was undone.

**Errors:** `WRITE_LOCKED`, `BUSY`.
