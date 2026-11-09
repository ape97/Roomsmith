# Agent guide: working with Roomsmith from Claude Code

Roomsmith exposes 120 tools (full reference: `MCP_API.md`). An agent edits the same project the user has open; every agent edit is
one undo step ("Agent: ...") and the user can switch agent write access off at any time.

## 1. Connect Claude Code

1. Start Roomsmith and open a project (the app serves the tools only while it runs).
2. Open the **Agents** panel in Roomsmith. It shows the exact command and a "Copy setup command" button. It looks like:

   ```
   claude mcp add roomsmith -- /Applications/Roomsmith.app/Contents/Helpers/roomsmith-mcp
   ```

   For a development build use the path of the built helper instead, for example
   `<repo>/.build/debug/roomsmith-mcp`. Run the command once in a terminal; afterwards `claude mcp list` shows `roomsmith`.
3. Start (or restart) `claude`. The tools appear under the server name `roomsmith` (names as in `MCP_API.md`; the client may
   show them prefixed, e.g. `mcp__roomsmith__...`).
   Without an MCP client you can test from a terminal: `roomsmith-mcp tools` lists the tools and
   `roomsmith-mcp call scene.list_objects '{"kind":"furniture"}'` calls one.
4. In the Agents panel the status line changes to "Agent connected". The switch "Allow agents to change the project" controls writing;
   with it off every read still works and `dryRun` calls still validate, writes fail with `WRITE_LOCKED`.

If the helper reports `NOT_RUNNING`, Roomsmith is not running. `UNAUTHORIZED` means the token file in
`~/Library/Application Support/Roomsmith/` changed; restart the helper (restart `claude`).

## 2. The safe workflow: list, get, move

Never guess ids or positions. Always:

1. **List**: `scene.list_objects` with `kind`, `query`, `roomId` or `category`. Each row has `id`, `name`, `rev`, position.
2. **Get** (when details matter): `scene.get_object` for footprint, group, state and the current `rev`.
3. **Change** with the revisions you just read:

   ```json
   {"tool":"scene.move_objects",
    "arguments":{"ids":["<id>"],"delta":{"x":-250,"y":0},
                 "expectedObjectRevisions":{"<id>":12}}}
   ```

   If the user touched the object in the meantime you get `CONFLICT`; list/get again and decide anew. Do not retry blindly.
4. **Check the result**: the response lists `changes` and the new positions. Report what changed, in plain words.

Useful habits:

* **Preview first** for anything non-trivial: add `"dryRun": true`, read `changes`, then repeat without it.
* **Several edits that belong together**: `app.batch` (one commit, one undo step, atomic; max 100 steps).
* **Take back a mistake**: `history.undo` (note: it undoes the most recent edit of anyone, also the user's). Prefer reading `canUndo`
  context first via `app.get_active_project`.
* **Follow the user**: `app.subscribe_changes` shows what the user changed meanwhile.
* Lengths are integer millimetres, angles degrees, X east, Y north. "250 mm to the left" is `delta.x = -250`.
* Change only what was asked. Untouched objects must keep their `rev`.
* `project.save` only works when the user already saved the project once (otherwise `NO_FILE`); ask the user to save first.

## 3. Example prompts (copy and paste)

Mapping for the first prompt: "sofa A" is the instance "Modular sofa - Corner A" of the built-in modular sofa (`catalog.insert_builtin`
key `sofa.modular`); "configuration 2" is `furniture.save_configuration` on that sofa's group with the name "Configuration 2";
wall snapping is `project.update_settings` with `snapEnabled` and `snapToWalls`.

**Move, snap, save a configuration**

> Show me all sofas in the living room, move sofa A exactly 250 mm to the left, turn on wall snapping and save this arrangement as configuration 2. Change nothing else.

Expected tool sequence: `scene.list_objects` (`category` "sofa" or `query`, `roomId` of the living room) -> `scene.get_object` ->
`scene.move_objects` (delta x -250, `expectedObjectRevisions`) -> `project.update_settings` (`snapEnabled: true`, `snapToWalls: true`) ->
`furniture.save_configuration` (group of the sofa, name "Configuration 2").

**Inspect only (no writes)**

> Give me an overview of the project: levels, rooms with areas, and how many pieces of furniture are in each room. Do not change anything.

**Add a room with furniture**

> On the ground floor, create a room "Study" of 3.5 m x 4 m in the north-east corner, put a desk against the north wall and a chair in front of it. Show me a dry run first.

**Rearrange safely**

> Rotate the armchair in the living room by 90 degrees clockwise and move the lamp 300 mm closer to the window. Use revisions so you do not overwrite my edits, and tell me if something is locked.

**Collisions**

> Check the bedroom for overlapping furniture and openings that are blocked by furniture. Propose fixes, apply only the ones I confirm.

**Catalog**

> Search the catalog for a 2 m wide sofa under 1500 EUR and link it to the sofa in the living room.

**Undo**

> Undo your last change.

## 4. Prompt kit and furniture skill

* [AGENT_PROMPTS.md](AGENT_PROMPTS.md): ready-to-paste prompts (furnish a room, build from a product link or photo, lamps,
  moods, checks, export, compare layouts) and a step-by-step recipe for detailed furniture that even small models can follow.
* [skills/roomsmith-furniture/SKILL.md](skills/roomsmith-furniture/SKILL.md): the same recipe as a portable skill. Copy the
  folder `roomsmith-furniture` into your client's skills folder.

## 5. Things to know

* Objects the user locked (`scene.set_locked`) give `LOCKED`; do not unlock them unless asked.
* `BUSY` is reserved for "the user is editing this object right now"; no tool returns it yet. If you see it, wait a moment and retry once.
* Long polls: `app.subscribe_changes` with `timeoutMs` at most 30000 (the client call times out at 60 s).
* Every call is recorded in `agent-audit.jsonl` and shown in the Agents panel under "Recent calls".
* The tools cannot run shell commands or touch other files; saving writes only the project's own file.
* **Rebuild from photos exactly.** The server sends this rule in its MCP `instructions` too. When the user gives photos of real furniture, windows, doors or fixed parts (kitchen, bath, floor, walls), copy them as they are: shape, legs, handles, frames, materials, colours and proportions, not a generic stand-in. Take sizes only from the user, the project or source plan, or a reliable product sheet. Never guess; if a size is missing, say so. Build windows and balcony or terrace doors openable, with real frames and handles: use `tiltTurn1`, `tiltTurn2`, `balconyDoor` or `balconyDoor2` (a window that can open gets a lever handle by itself), and check the result in the 3D view with `walk.toggle_door` (`mode` turn or tilt). Ignore furniture in the photos that the user says is not theirs.

## 6. Working rules for agents

* Never claim a result that was not read back from a tool response; report failures and `dryRun` results as what they are.
* Lengths are integer millimetres; do not round or "fix" values silently. Corrections must be visible and undoable.
* Every change goes through the tools (one undo step each); never edit project files on disk while Roomsmith has the project open.
* The user's data stays local: do not copy project contents, photos or tokens into other places.
