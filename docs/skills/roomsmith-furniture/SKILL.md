---
name: roomsmith-furniture
description: Build detailed furniture, materials and lamps in a running Roomsmith project through its MCP tools. Use when the user asks to create, copy from a photo or product page, refine, colour or light a piece of furniture in Roomsmith.
---

# Build detailed furniture in Roomsmith

Use this when the Roomsmith MCP server is connected (tools such as `furniture.create_definition`). Roomsmith never
fetches web pages: if the user gives a product link, read the page yourself with your own web tool.

## Install

Copy the whole folder `roomsmith-furniture` (it contains this `SKILL.md`) into your assistant's skills folder. If your
assistant has no skills folder, paste the text below as the system prompt or as the first message.

## Rules that always apply

* All lengths are whole millimetres (90 cm = 900). No decimals. X east, Y north, Z up.
* Never guess a size. If width, depth or height is unknown, ask the user.
* Look before you change: `scene.list_objects` / `scene.get_object`. Never invent ids.
* Change only what was asked. Say in plain words what you changed.
* Reuse before you create: look at `scene.list_objects` with `{"kind":"material"}` first (see Materials).
* Materials are referenced by NAME in components (`"material": "Oak"`). Create the material first, or reuse an existing one.
* Names of materials are unique, not case sensitive. If `material.create` says the name exists, pick another name
  (for example "Oak 2") or reuse the existing one.

## Ids from earlier calls

Every result carries ids. Copy them exactly, never invent one.
* A create call returns the new thing's `id` (for `furniture.create_definition` it is the design id, for
  `furniture.create_instance` it is the placed instance id). Use "the `id` field from the result of call N".
* List tools return `{"items":[...]}`. Read the `id` from the row inside `items` (rows have `kind`, `name`, `id`).
* In the examples below `<design id>`, `<instance id>` and `<wall id>` mean such copied ids.

## Local coordinates of a design

Origin = centre of the footprint on the floor. `+X` right, `+Y` back, `+Z` up. The front of a piece is on the `-Y` side.
A part's `position` is the centre of its box. `size` is `{"width": along X, "depth": along Y, "height": along Z}`.
Centre = lower edge + half the size. Parts stay inside the overall `size`, except small overhangs: a top panel up to 20 mm, knobs and handles up to about 40 mm.

## Find the room and the wall (do this before placing)

1. Call `scene.list_objects` with `{"kind":"room"}`. Pick the room by `name`. Its `points` are the inner corners (mm). If `geometry.measure_distance` later gives a different gap than expected, shift the piece by the difference (the room outline is not always on the wall faces).
   Inner faces: west = smallest `x`, east = largest `x`, south = smallest `y`, north = largest `y`. Centre of the room =
   middle of those values.
2. Call `scene.list_objects` with `{"kind":"wall"}`. Pick the wall row by its `start` and `end` points, not by its position in
   the list or its direction: south wall = both `y` the lowest, north wall = both `y` the highest, west wall = both `x` the
   lowest, east wall = both `x` the highest. Read the wall list yourself, find the row, and COPY its `id` string literally into the next call (the `@N.path` placeholder syntax of test harnesses only works for whole fields, not for choosing a row).
   Wall points are centre lines. Never use them as positions: use the room's inner faces.
3. Place the piece with its back to the wall. D = the piece's depth (its `size.depth`), G = gap to the wall (10 mm, or 0 to touch).
   Along the wall use the room's middle (or the user's value).

| Wall | `position` of the piece centre | `rotationDeg` |
|---|---|---|
| south | `x` = along the wall, `y` = south face + G + D/2 | 180 |
| north | `x` = along the wall, `y` = north face - G - D/2 | 0 |
| west | `x` = west face + G + D/2, `y` = along the wall | 90 |
| east | `x` = east face - G - D/2, `y` = along the wall | 270 |

   The rotation makes the front face into the room. D is always the piece's depth, also at 90 and 270.
   Example (room 0..5000 x 0..4000): sideboard 1200 x 400 against the south wall, centred, 10 mm gap: `x` 2500,
   `y` = 0 + 10 + 200 = 210, `rotationDeg` 180. Against the north wall: `y` = 4000 - 10 - 200 = 3790, `rotationDeg` 0.
   All four were verified: `geometry.measure_distance` to the wall gave 10.

## Steps

1. **Measure.** Write down overall width, depth, height in mm (from the user, a product sheet or notes).
2. **Choose 4 to 8 main parts** (top, sides, back, base, seat, backrest, doors, drawers). See "Typical sizes" below.
3. **Add small details**: legs, feet, handles, trim, plinth, door gaps, cushions, lamp shade. Aim for 8 to 20 parts.
4. **Compute positions** of every part in local coordinates (see above). Part names must be unique.
5. **Choose colours.** Reuse an existing material by name. Create only what is missing (see "Materials").
6. **Create the design.** `furniture.create_definition` with `name`, `category`, `size`, `components`
   (each: `name`, `shape`, `position` `{x,y,z}`, `size`, optional `rotation` `{x,y,z}` degrees, `material` = material
   NAME). Keep the returned `id`.
7. **Place it.** `furniture.create_instance` with `definitionId`, `position` `{x,y}` (footprint centre, plan mm),
   `rotationDeg`, `name`. Rotation 0: back towards north (stands against a north wall); 90 back to west; 180 back to
   south; 270 back to east. Keep the returned `id` (the placed instance id).
   Check the gap: `geometry.measure_distance` with `{"from":{"id":"<instance id>"},"to":{"id":"<wall id>"}}`.
   Each side is `{"id": ...}` or a point `{"x":...,"y":...}`. Bare id strings are rejected. The result has
   `distanceMm`. Walls are measured by their surface, so a piece 10 mm off the wall gives 10.
8. **Render and look.** Look from inside the room with an explicit camera. Use `render.scene_image` with
   `{"camera":{"mode":"orbit","target":{"x":<piece x>,"y":<piece y>,"z":400},"distanceMm":3500,"yawDeg":<rotationDeg of the piece>,"pitchDeg":-20},"width":1024,"height":768}`.
   `distanceMm` 3500 suits rooms at least 4 m deep in the viewing direction; use about 2000 for smaller rooms (the camera must stay inside the room). To save the PNG add `"path"` (absolute file path, the folder must exist) and `"overwrite": true` (to replace an existing file). `yawDeg` is the direction the camera looks. It equals the piece's `rotationDeg` (south wall 180, north 0, west 90, east 270; all verified).
   Do NOT use `preset: "frame"` for a piece against a wall: for the south wall it shows only the grey outside of the wall.
   Use `frame` only for pieces away from the walls.
   If the picture is too dark (a piece in a wall's shadow), do not change the colours yet. Call `light.set` with
   `{"mood":"daylight","applyMoodTime":true}` (or `timeMinutes` such as 780, or `exposure` such as 1) and render again.
   Compare with that second picture before you change any colour.
   Fix with `furniture.update_definition` (`updateComponents`, `addComponents`, `removeComponents`; parts are referenced by
   name) and render again. Repeat until it looks right.

Shortcut for plain pieces: `furniture.create_from_template` (`cabinet`, `table`, `shelf`, `sofa`, `box`), then refine.
From a photo: `library.create_from_photo` (needs at least one dimension in `dimensions`; approximation from five
templates), then `library.place`, render, refine.

## Materials

First call `scene.list_objects` with `{"kind":"material"}`. REUSE an existing material by name before you create one.
Every project already has: Oak, Walnut, Birch, White lacquer, Grey fabric, Beige fabric, Brown leather, Black metal, Chrome,
Stainless steel, Glass, White ceramic, Leaf green, Soil, Screen black.

| Look | Name to use | Colour if you must create it |
|---|---|---|
| oak | Oak | `#C9A271` |
| walnut | Walnut | `#6B4A32` (`#5C4033` is too dark) |
| birch | Birch | `#E2CBA0` |
| white lacquer | White lacquer | `#F2F2EE` |
| black metal | Black metal | `#222427` |
| brass | none built in: create "Brass" | `#B5A642`, `finish` `brushed`, `roughness` 0.3, `metallic` 0.6 |
| chrome | Chrome | `#C9CED3` |

`material.create` fields: `name` (required, unique, not case sensitive), `color` (required, `#RRGGBB`), `roughness` 0 (mirror)
to 1 (matte), default 0.7, `metallic` 0 to 1, `opacity` 0 to 1, `finish` (`matte`, `satin`, `brushed`, `polished`), `pattern`
(`none`, `stripes`, `grid`, `tiles`, `wood`, `fabric`, `leather`), optional `color2`. If the name is taken the call fails with
`INVALID_ARGUMENT`: reuse that material or pick another name.

Rule: in components use the material name (simplest; names are unique).

## Categories

`category` of `furniture.create_definition` is free text (default `Custom`). Always use one of these eight values so the
piece is grouped in the library: `Living`, `Bedroom`, `Kitchen`, `Bathroom`, `Office`, `Dining`, `Decor`, `Lighting`.
Pieces that fit none exactly:
* Sideboard, dresser, console, TV bench, bookshelf, storage in a living room: `Living`.
* Wardrobe, dresser, bed, nightstand, storage in a bedroom: `Bedroom`.
* Desk, office shelf, filing cabinet: `Office`. Dining table, chairs, buffet: `Dining`.
* Plants, vases, mirrors, rugs, pictures: `Decor`. Lamps: `Lighting`.

## Typical sizes and parts (mm)

* Leg: 30 to 50 square, 80 to 150 high. Shape `box` (round legs: upright `cylinder`).
* Door and drawer front: 18 to 20 thick, shape `panel`. Shelf, top, bottom, side: 18 to 25 thick, `panel`. Back: 8 to 12, `panel`.
* Handle bar: 100 to 160 long, about 14 thick. Use a thin `box` (no rotation needed) or an upright `cylinder` (it stands along Z,
  height = length). For a horizontal bar use a thin box.
* A `cylinder` stands along Z. `rotation` `{"x":90}` lays it along Y (a knob pointing out of a front; verified).
* Cushions: `cushion`. Round things (stool top, vase, plate, lamp base): `cylinder`. Balls and round knobs: `sphere`.
* A door sits in front of the body: `y` = front edge of the body - door thickness / 2. Two doors: each about half the width.

Storage furniture (sideboard, dresser, cabinet):
* Plinth: a dark `box`, height 60 to 100, set back 30 mm from the front and sides (so it is 60 mm narrower and 30 mm
  shallower than the body at the front).
* Drawer fronts: all the same height, 3 mm gaps, whole mm. Front height = (free height - 3 x (number of fronts - 1)) / number.
  Example: free height 618, 3 fronts: 3 x 204 + 2 x 3 = 618. Pick the free height so the result is a whole number.
* Knobs: `sphere` 20 to 30 mm (or a `cylinder` with `rotation` `{"x":90}`), centred on each drawer front. Front face = the outer surface of the drawer front
  (local `y` = front centre `y` - thickness / 2). Knob centre `y` = front face `y` - knob diameter / 2.
  Example: front centre `y` -199, thickness 18 gives front face -208; a 26 mm sphere gets centre `y` -221 (34 mm in front of a 400 deep body; knobs may protrude up to about 40 mm).
  Material: Black metal or Brass.
* If the user names no colour for a part, use the main material of the piece or a neutral one (White lacquer, Black metal),
  and tell the user which you chose.
* Top panel: it may overhang the body by 10 to 20 mm at the front and sides. The API accepts parts outside the declared `size`
  (verified). Keep `size` equal to the body so that distances and collision checks use the body.
  Other parts stay inside `size`; only the top panel (up to 20 mm) and knobs or handles (up to about 40 mm) may protrude.

## Lamps

Build the lamp body with `furniture.create_definition` (category `Lighting`), then `light.set_emitter` with
`definitionId`, `kind` (`point` or `spot`), `positionMm` `{x,y,z}` in design space, `kelvin` (2700 warm), `lumens`
(about 800 for a 60 W bulb). Place it with `furniture.create_instance`, keep the instance `id`, then `light.toggle` with
`{"id":"<instance id>","on":true}`. Mood: `light.set` with `mood` (`daylight`, `evening`, `night`, `overcast`) and
`applyMoodTime: true`.

## Colours of walls and floors

`scene.set_material` with `ids`, `material` (id or name) and `slot`: `wallBoth`, `wallLeft`, `wallRight`, `roomFloor`,
`roomCeiling`, `openingFrame`, `allComponents`, or `component:<id>`. For one placed piece use `furniture.update_instance`
`materials`.

## Small example (a stool, 300 x 300 x 450)

```json
{"tool":"furniture.create_definition","arguments":{
  "name":"Stool","category":"Living","size":{"width":300,"depth":300,"height":450},
  "components":[
    {"name":"seat","shape":"cushion","position":{"x":0,"y":0,"z":425},"size":{"width":300,"depth":300,"height":50}},
    {"name":"leg_a","shape":"cylinder","position":{"x":-100,"y":-100,"z":200},"size":{"width":40,"depth":40,"height":400}},
    {"name":"leg_b","shape":"cylinder","position":{"x":100,"y":-100,"z":200},"size":{"width":40,"depth":40,"height":400}},
    {"name":"leg_c","shape":"cylinder","position":{"x":-100,"y":100,"z":200},"size":{"width":40,"depth":40,"height":400}},
    {"name":"leg_d","shape":"cylinder","position":{"x":100,"y":100,"z":200},"size":{"width":40,"depth":40,"height":400}}
  ]}}
```

## Full example: TV bench against the north wall

Request: "TV bench, oak, 1600 x 400 x 450 mm, two doors, four legs, brass handles, against the north wall of the
living room, centred, 10 mm from the wall."

Call 1: `scene.list_objects` with `{"kind":"room"}`. Read the room's `points`. Here the room spans x 0 to 5000 and y 0 to
4000. Centre X = 2500. North face = 4000. Y = 4000 - 10 - 400 / 2 = 3790.
Call 2: `scene.list_objects` with `{"kind":"wall"}`. The north wall is the one whose `start.y` and `end.y` are the
largest. Keep its `id` (the `id` of that row in `items`).
Call 3: look at the materials (`scene.list_objects` with `{"kind":"material"}`). "Oak" exists, so reuse it. Brass does not exist: create it.

```json
{"tool":"material.create","arguments":{"name":"Brass","color":"#B5A642","finish":"brushed","roughness":0.3,"metallic":0.6}}
```

Call 4: the design. The body is 1600 wide, 400 deep. Legs are 100 high, so the body starts at z 100. The doors are 18 thick
and sit on the front (-Y) side. Each door is 768 wide at x = -394 and 394: 20 mm gap in the middle (over the 20 mm divider), 22 mm to each outer side. Handles are upright brass cylinders next to the centre gap.

```json
{"tool":"furniture.create_definition","arguments":{
  "name":"TV bench oak","category":"Living","size":{"width":1600,"depth":400,"height":450},
  "components":[
    {"name":"leg_front_left","shape":"box","position":{"x":-730,"y":-150,"z":50},"size":{"width":40,"depth":40,"height":100},"material":"Oak"},
    {"name":"leg_front_right","shape":"box","position":{"x":730,"y":-150,"z":50},"size":{"width":40,"depth":40,"height":100},"material":"Oak"},
    {"name":"leg_back_left","shape":"box","position":{"x":-730,"y":150,"z":50},"size":{"width":40,"depth":40,"height":100},"material":"Oak"},
    {"name":"leg_back_right","shape":"box","position":{"x":730,"y":150,"z":50},"size":{"width":40,"depth":40,"height":100},"material":"Oak"},
    {"name":"bottom","shape":"panel","position":{"x":0,"y":20,"z":110},"size":{"width":1600,"depth":360,"height":20},"material":"Oak"},
    {"name":"top","shape":"panel","position":{"x":0,"y":20,"z":440},"size":{"width":1600,"depth":360,"height":20},"material":"Oak"},
    {"name":"side_left","shape":"panel","position":{"x":-790,"y":20,"z":275},"size":{"width":20,"depth":360,"height":310},"material":"Oak"},
    {"name":"side_right","shape":"panel","position":{"x":790,"y":20,"z":275},"size":{"width":20,"depth":360,"height":310},"material":"Oak"},
    {"name":"divider","shape":"panel","position":{"x":0,"y":14,"z":275},"size":{"width":20,"depth":348,"height":310},"material":"Oak"},
    {"name":"back","shape":"panel","position":{"x":0,"y":194,"z":275},"size":{"width":1560,"depth":12,"height":310},"material":"Oak"},
    {"name":"door_left","shape":"panel","position":{"x":-394,"y":-169,"z":275},"size":{"width":768,"depth":18,"height":306},"material":"Oak"},
    {"name":"door_right","shape":"panel","position":{"x":394,"y":-169,"z":275},"size":{"width":768,"depth":18,"height":306},"material":"Oak"},
    {"name":"handle_left","shape":"cylinder","position":{"x":-30,"y":-185,"z":275},"size":{"width":14,"depth":14,"height":140},"material":"Brass"},
    {"name":"handle_right","shape":"cylinder","position":{"x":30,"y":-185,"z":275},"size":{"width":14,"depth":14,"height":140},"material":"Brass"}
  ]}}
```

Call 5: place it. Use the `id` from the result of call 4 as `definitionId`.

```json
{"tool":"furniture.create_instance","arguments":{"definitionId":"<design id>","position":{"x":2500,"y":3790},"rotationDeg":0,"name":"TV bench"}}
```

Call 6: `geometry.measure_distance` with `{"from":{"id":"<instance id>"},"to":{"id":"<north wall id>"}}`. Expect `distanceMm` 10.
Call 7: `render.scene_image` with `{"camera":{"mode":"orbit","target":{"x":2500,"y":3790,"z":400},"distanceMm":3500,"yawDeg":0,"pitchDeg":-20},"width":1024,"height":768}`. The piece has `rotationDeg` 0, so `yawDeg` is 0. Look at the picture. (The room is 4 m deep, so 3500 is fine; use about 2000 in a smaller room.)

## Common mistakes

* Wrong axis: the front is `-Y`, height is `Z`; in `size` `width` is X, `depth` is Y, `height` is Z.
* Using a corner instead of the box centre for `position` (a leg standing on the floor has `z` = half its height).
* Wrong unit: centimetres or metres instead of millimetres; decimals such as `487.5` are rejected.
* Using a material name that does not exist yet (create it first or look it up with `scene.list_objects` with `kind: "material"`).
* Creating a material whose name is taken (names are unique). Reuse the existing one.
* `preset: "frame"` for a piece against a wall (grey picture of the wall's outside). Use an explicit camera from inside the room.
* Wrong `rotationDeg` for a wall: south 180, north 0, west 90, east 270.
* Duplicate part names inside one design.
* Placing by the wall's centre line instead of its surface.
* `geometry.measure_distance` with bare id strings instead of `{"id": ...}`.
* Rebuilding the whole piece for a small change instead of `furniture.update_definition`.
* Forgetting to render and look before saying "done".
