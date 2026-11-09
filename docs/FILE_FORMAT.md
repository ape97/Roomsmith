# Roomsmith Markdown (project file format)

Own format. Goal: fast to parse, readable by people and AI agents, diff-friendly, lossless.
Code: `Sources/RoomsmithCore/Persistence/` (`RoomsmithMarkdown`, `ProjectPackage`, `ProjectMigration`).
Agents may read `project.md` directly. Edits go through the running app's API (MCP/IPC), never by editing the file
while the app is open: the app owns the file and rewrites it on every save.

## Package

```
Name.roomsmith/
  project.md      the whole document (everything except binaries)
  assets/         imported files, named <first 16 hex of sha256>.<ext> (same content = same file)
  backups/        project-<yyyyMMdd-HHmmss-SSS>.md (UTC), previous states, newest 10 kept
```

## project.md structure

1. Front matter between `---` lines: `format: roomsmith`, `schema: 5`, `id`, `name`, `revision` (Int, document revision).
2. `# <name>` title (informational), then `## <Section>` blocks. Prose lines are ignored.
3. A section holds bullets (`- key: value`) and/or tables (header row, `|---|` separator, rows).
4. Sections `Definitions`, `Groups`, `Products` hold one `### <uuid> · <name>` block per item (bullets plus `#### <Table>` tables).
5. Sections and columns are read **by name**; order is free; missing optional columns/keys take defaults; unknown
   sections/tables/columns/keys give a warning, never an error. Required values missing or malformed give a
   `PersistenceError` with the 1-based line number.

## Encoding rules

| Type | Text |
|---|---|
| length (`MM`) | integer millimetres, no unit: `4250`, `-300` |
| point | `x,y` or `x,y,z` (ints) |
| size | `WxDxH` (ints) |
| rotation | `rx,ry,rz` degrees, shortest exact Double (`String(describing:)`: `12.5`, `-90.0`) |
| Double | same shortest exact form |
| bool | `yes` / `no` |
| nil | `-` (a text that is literally `-` is written `\-`) |
| UUID | lowercase |
| colour | `#RRGGBB` |
| enum | raw value (`door`, `cushion`, `orbit`, ...) |
| list | `a; b; c` (`;` inside an element is `\;`); empty cell = empty list |
| point list | `x,y; x,y; ...` |
| material map | `componentUuid=materialUuid; ...` sorted by key (empty cell = empty map, `-` = nil where optional) |
| text | backslash → two backslashes, pipe → backslash + pipe, line break → `\n` (CR → `\r`); bullet keys also escape `:` |

Cells are written as `| value |`; exactly one blank on each side is stripped when reading, so leading/trailing spaces in
text survive. Output is deterministic (dictionaries sorted by UUID/key), so unchanged projects produce identical files.

## Sections

`rev` columns are the per-object revision (Int). `-` = nil.

- **Settings** (bullets): `displayUnit` (mm|cm|m), `snap.enabled`, `snap.grid`, `snap.tolerance`, `snap.toWalls`,
  `snap.toObjects`, `snap.toGrid`, `snap.angleStep`, `collisionWarnings`, `defaultWallThickness`, `defaultWallHeight`, and the
  lighting of the 3D view: `lighting.northDeg` (-360...360), `lighting.dayOfYear` (1...366), `lighting.timeMinutes` (0...1439),
  `lighting.latitudeDeg` (-66...66), `lighting.mood` (daylight|evening|night|overcast), `lighting.shadows`, `lighting.exposure`
  (EV, -3...3). Missing keys take the defaults (north 0, day 172, 13:00, latitude 50, daylight, shadows on, exposure 0);
  out-of-range values are clamped on read.
- **Levels**: `id | name | elevation | height | visible | locked | rev`
- **Walls**: `id | level | start | end | thickness | height | leftMaterial | rightMaterial | locked | rev`
- **Rooms**: `id | level | name | points | floorMaterial | ceilingMaterial | showFloor | showCeiling | rev`
- **Openings**: `id | wall | kind | name | offset | width | height | sill | flipped | inward | frameMaterial | style | handle | frameWidth | mullionCols | mullionRows | glass | rev`.
  `style` (smooth|panel2|panel4|glass|sliding for doors, tiltTurn1|tiltTurn2|fixed|balconyDoor|balconyDoor2 for windows; a style that does not
  suit `kind` reads as the default: smooth for a door, fixed for a window), `handle` (lever|knob|bar|none), `frameWidth` (mm,
  clamped to 20...150), `mullionCols` and `mullionRows` (clamped to 0...6), `glass` (clear|frosted|tinted). Files without these
  columns keep the default look of the kind. `balconyDoor2` is a new value in the same column (no format version bump): an older build
  rejects a file that contains it, and a door that carries it reads as `smooth`. Whether a window opens is not stored: it follows from
  style and size, and the open pose is view state only.
- **Dimensions**: `id | level | a | b | offset | rev`
- **Materials**: `id | name | color | roughness | metallic | opacity | texture | textureTile | preset | finish | pattern | color2 | patternSize | patternAngle | grout | clearcoat | specular | rev`.
  `preset` is the id of the built-in material preset last applied (`-` = none), `finish` (matte|satin|brushed|polished),
  `pattern` (none|stripes|grid|tiles|wood|fabric|leather; a procedural pattern drawn from `color` and `color2`, `-` = no second
  colour), `patternSize` (mm per repeat) and `patternAngle` (degrees), `grout` (mm, clamped to 0...100), `clearcoat` and
  `specular` (0...1). The older columns are unchanged; missing new columns take the defaults of a new material.
- **Assets**: `id | kind | storedName | originalName | sha256 | byteCount | measuredSize | importScale | notes | rev`
- **Backgrounds**: `id | level | asset | calibrationA | calibrationB | calibrationLength | origin | opacity | visible | rev`
- **Camera** (bullets): `mode` (`orbit`, `firstPerson`, `top`, `free`), `target`, `distance`, `yaw`, `pitch`, `fov`. In `firstPerson` and `free` the `target` is the eye position.
- **Saved cameras**: `id | name | mode | target | distance | yaw | pitch | fov | rev`
- **Definitions**: per `### <uuid> · <name>`:
  - bullets: `name`, `category`, `size`, `defaultState`, `product`, `builtin`, `catalogKey`, `tags`, `rev`
  - `#### Components`: `id | name | shape | position | size | rotation | pivot | material | mesh | visible`
  - `#### Lights` (only written when the design has lamps; at most 8 are kept): `id | name | kind | position | yaw | pitch | cone | kelvin | color | lumens | range`.
    `kind` is point|spot, `position` is in the design's space, `yaw`/`pitch`/`cone` aim a spot, `kelvin` is the colour
    temperature, `color` (`#RRGGBB`, `-` = use `kelvin`) overrides it, `lumens` is the brightness, `range` the reach in mm.
    Values outside their ranges are clamped on read; a repeated id gets a fresh one.
  - `#### States`: `id | name | component | position | rotation | size | visible`. One header row per state
    (`component` = `-`; carries `name` and the state footprint in `size`), then one row per component override
    (`-` fields keep the base value).
  - `#### Options` (only written when the design has option groups; at most 12 groups of at most 24 choices):
    `group | choice | name | default | component | material | visible`. One header row per group (`choice` = `-`;
    carries `name` and the `default` choice id, `-` = the first choice), one header row per choice (`component` = `-`;
    carries `name`), then one row per component effect of that choice (`material` and `visible` as `-` leave the part
    alone; `visible` = `no` hides it, `yes` keeps it as visible as the design and state allow). Options change only
    material and visibility, never size or pose.
  - `#### Tracks`: `id | from | to | durationMs | easing`
  - `#### Keyframes`: `track | key | t | component | position | rotation | size | visible`. Header row per keyframe
    (`component` = `-`, carries `t`; `key` = index in the track), then one row per component override.
- **Instances**: `id | definition | level | name | position | rotation | size | materialOverrides | state | group | product | visible | locked | lightOn | allowsOverlap | options | rev`
  (`lightOn`: the lamps of the piece are on; a missing column reads as `yes`. `allowsOverlap`: the piece may overlap
  furniture, walls and openings without a collision warning and never stops a dragged piece; a missing column reads as
  `no`, so files from before the column load unchanged; the column came with schema 4, so an older app refuses such a
  file instead of dropping the value. Flat floor pieces such as rugs (underside at most 0 mm above the
  floor, height up to 150 mm) behave the same without the flag; that is computed, not stored. `options`: the chosen option per group as `group=choice; ...` of ids, `-` = all defaults;
  a missing column reads as no selection; the column came with schema 5.)
- **Groups**: per `### <uuid> · <name>`: bullets `name`, `level`, `origin`, `rotation`, `members`, `activeConfiguration`,
  `product`, `locked`, `rev`; `#### Configurations`: `id | name | member | local | rotation | visible | state | materialOverrides`
  (header row per configuration with `member` = `-` carrying `name`, then one row per member pose).
- **Products**: per `### <uuid> · <name>`: bullets `name`, `category`, `description`, `notes`, `manufacturer`, `model`,
  `articleNumber`, `priceMinor` (cents), `currency`, `priceDate`, `dimensions`, `weightGrams`, `material`, `color`,
  `files`, `images`, `tags`, `status`, `variants`, `rooms`, `definition`, `rev`, and `custom.<key>` for free fields;
  `#### Links`: `id | title | url`.

## Example

```markdown
---
format: roomsmith
schema: 5
id: 3f2a9c1e-0b7d-4c55-9a51-6d1d7a0b2e10
name: Flat
revision: 12
---
# Flat

## Settings

- displayUnit: cm
- snap.enabled: yes

## Levels

| id | name | elevation | height | visible | locked | rev |
|---|---|---|---|---|---|---|
| 8c0f5d52-1b8e-4a7e-8d0e-2f6a3e1c9b01 | Ground floor | 0 | 2500 | yes | no | 3 |

## Walls

| id | level | start | end | thickness | height | leftMaterial | rightMaterial | locked | rev |
|---|---|---|---|---|---|---|---|---|---|
| 1d6b7c2a-93f4-4e0a-b1c7-5a8e2d4f6a02 | 8c0f5d52-1b8e-4a7e-8d0e-2f6a3e1c9b01 | 0,0 | 4250,0 | 115 | 2500 | - | - | no | 1 |
```

What is **not** in the file: the walk-mode settings, tabs and the compare split of the workspace, and the library (a separate
global store). They are view or app state.

## Atomic save, backups

`ProjectPackage.save`: encode, write `project.md.tmp-<uuid>`, fsync, copy the old `project.md` to
`backups/project-<timestamp>.md` (prune to the newest 10), then `rename(2)` over `project.md` and fsync the folder.
A failure or crash at any step leaves the previous `project.md` untouched; leftover `project.md.tmp-*` files are ignored
by `load`. Saving unchanged content writes nothing and creates no backup. `ProjectPackage.listBackups` returns newest first.

## Migration

`ProjectMigration.migrate(text)` runs before decoding and works on text, so line numbers stay valid. It is idempotent
(a file at the current schema passes through unchanged). Newer schemas are rejected.

- **schema 1 → 2**: Openings column `elevation` renamed `sill`; `## Settings` (did not exist) appended with defaults.
  `decode`/`load` migrate automatically and report a `migrated: ...` warning; the next save writes the current schema.
- **schema 2 → 3**: additive only (lighting keys, opening/material columns, lights, lightOn); stamp only. A schema 1 file
  runs through both steps (1 → 2 → 3).
- **schema 3 → 4**: camera mode `free` (also for saved cameras); Instances column `allowsOverlap` (missing reads as `no`); stamp only. A schema 1 or 2 file runs through every step.
- **schema 4 → 5**: furniture options: Definitions table `Options`, Instances column `options` (missing reads as no selection); stamp only.

The rule is that every format addition (column, section, bullet key) bumps the schema number; `Project.currentSchemaVersion` is 5; the columns and keys for opening details, material patterns, lighting and lamps (added with schema 3) are optional on read (defaults above). An older app refuses a newer schema
(`unsupported schema N (written by a newer Roomsmith version)`), so it never loads a file and silently drops the parts it
does not know when saving again. New readers keep migrating older schemas via `ProjectMigration`, a chain of single steps (1 → 2 → 3 → 4 → 5 …), each stamping only its own target schema.

Read-back details: an empty string list element (`[""]`) reads back as an empty list. Custom keys (`custom.<key>`) are
trimmed when read, so keys must not have leading or trailing whitespace (such a key would not round-trip unchanged).
