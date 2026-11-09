# Prompt kit: build your home by talking to your AI

Roomsmith is a floor planner made to be driven by an AI assistant. Connect any MCP client (Claude Code or another one),
open a project, and describe what you want in plain words: rooms, walls, windows, furniture built part by part, materials,
lamps that really glow, an evening mood, a rendered picture to check the result. You and the AI work on the **same open
project** at the same time. Whatever the AI does shows up live in the plan and in 3D, you can keep dragging things by hand,
and **undo covers both**: every AI change is exactly one undo step named "Agent: ...", and you can switch the AI's write
access off in the Agents panel whenever you like.

This page gives you ready-to-paste prompts that work even with small, fast models. Connection setup is in
[AGENT_GUIDE.md](AGENT_GUIDE.md); every tool is listed in [MCP_API.md](MCP_API.md).

## 1. How to use

1. Start Roomsmith, open (or create) a project and connect your MCP client as described in [AGENT_GUIDE.md](AGENT_GUIDE.md).
   Writing must be switched on in the **Agents** panel.
2. Optional but recommended with small models: paste the **starter rules** below once at the start of the chat.
3. Copy a prompt from section 2, replace everything in `[square brackets]` with your own values, paste, send.
4. Read the answer. The AI should tell you what it changed and show you a picture. If it is not right, just say what to
   change ("make the legs thinner", "move it 20 cm left"). Or press Undo in Roomsmith.

**Starter rules (paste once):**

> You control my Roomsmith project through its tools. Rules: (1) All lengths are whole millimetres (1 cm = 10 mm, 1 m = 1000 mm); X is east, Y is north, Z is up. (2) Before changing anything, look: use scene.list_objects and scene.get_object, never guess ids or positions. (3) Only change what I asked for. (4) After building something, render a picture with render.scene_image, look at it, and fix what is wrong. (5) At the end tell me in plain words what you changed. If a tool returns an error, read the message, fix the arguments and try again once; if it still fails, tell me.

Tips:

* Give real sizes whenever you have them. Roomsmith never invents sizes for you; the AI should ask if one is missing.
* Say "show me a dry run first" if you want to see the planned changes before anything is written.
* Small models do best with one job per prompt. Build a piece, check it, then place it.
* Units in the prompts below are written in millimetres where an exact number matters.

## 2. Example prompts

### 2.1 Look around first (no changes)

> Give me an overview of my open Roomsmith project: levels, rooms with their areas, and how many pieces of furniture are in each room. Do not change anything.

Reads `project.get_summary`, `scene.list_objects` and `report.rooms`, then answers in words.

### 2.2 Furnish a room from a description

> Furnish the room "[Living room]" as [a cosy living room for two people with a sofa facing the window, a low coffee table, a TV board on the opposite wall and one reading corner]. Use the built-in catalogue for simple pieces and build anything special from parts. Keep 90 cm free in front of every door. Show me a picture when you are done and list what you placed.

Finds the room and walls, picks catalogue pieces (`catalog.list_builtin`, `catalog.insert_builtin`), builds missing pieces with `furniture.create_definition`, places them, then checks `report.clearances`.

### 2.3 "I want this product" from a web link

> I want this piece in my plan: [https://example.com/product-page]. Open the page yourself, read the dimensions, colours, materials and look at the product photos, and tell me what you found. If a size is missing, ask me. Then build it in Roomsmith part by part (legs, handles, trim, cushions), give it the right colours, put it in [the living room, against the north wall] and save the link and price as a product record.

Important: **Roomsmith never fetches web pages.** Your MCP client (or its web tool) reads the page and the photos; Roomsmith only
receives the numbers and the result. Use a client that can browse, or paste the dimensions and colours into the chat yourself.
Roomsmith then builds the piece (`furniture.create_definition`), places it (`furniture.create_instance`) and can keep the shop
link, price and notes (`catalog.create_product` with `links` and `linkTo`).

### 2.4 Build a detailed piece from a photo

> Here is a photo of a [three-seat sofa with arm rests]: [/absolute/path/to/photo.jpg]. It is [2200] mm wide and [900] mm deep. Create it in my Roomsmith library from the photo, place it in the living room, then compare the picture of the result with the photo and improve whatever looks different (colour, legs, cushions, proportions).

Uses `library.create_from_photo` (analysed on your Mac; it picks the closest of five builder templates, so it is an
approximation, not a 3D scan), `library.place`, `render.scene_image`, and refines with `furniture.update_definition`.
At least one dimension is required.

### 2.5 A desk exactly where I want it

> Put a desk of 2000 x 900 mm under the window in [the study], with its back [100] mm away from the wall. Centre it on the window. Check the real distance to the wall afterwards and tell me the number.

The AI reads the wall and window (`scene.list_objects`, `scene.get_object`), builds or inserts a desk, places it with exact
millimetres (`furniture.create_instance`, `scene.move_objects`) and verifies with `geometry.measure_distance`.

### 2.6 Build a detailed piece from scratch

> Build me a bookshelf from parts: [1800] mm high, [900] mm wide, [300] mm deep, with 5 shelves, side panels, a thin back panel, a small plinth and oak colour. Then place it against the [north] wall of the [study], render a picture and fix anything that looks wrong.

The AI follows the recipe in section 3: `furniture.create_definition` with about ten parts, `material.create`, placement,
render, correction with `furniture.update_definition`.

### 2.7 A lamp that really glows

> Make a floor lamp: a round base, a thin pole and a lamp shade, about 1600 mm high. It should give warm light (2700 K). Put it next to the sofa, switch it on and show me the room in a picture.

`furniture.create_definition` (category "Lighting"), `light.set_emitter` (a `point` lamp at the shade, `kelvin` 2700,
`lumens` about 800), `furniture.create_instance` (keep the returned instance `id`), `light.toggle` with `id` (the placed
instance id) and `on: true`, `render.scene_image`. At most 8 lamps
render at the same time and lamps cast no shadows.

### 2.8 Change wall and floor materials

> In the [bedroom], paint the walls [light sage green], put [oak plank] flooring on the floor and give the ceiling a white matte finish. Show me a picture.

`material.create` (colour, `pattern: "wood"` for planks, `finish`), then `scene.set_material` with the slots `wallBoth`,
`roomFloor`, `roomCeiling` (or `geometry.update_room`). `material.list_presets` and `material.apply_preset` give ready-made
looks.

### 2.9 Evening or night mood

> Switch the scene to an evening mood at 19:30, turn on all the lamps in the living room and render a picture from the door looking into the room. Then show me the same room at night.

`light.set` with `mood` and `applyMoodTime`, `light.get` to find the lamp pieces (`pieces[].id`), `light.toggle` once per piece with `id` and `on: true`,
`render.scene_image` with a `camera`. Moods: `daylight`, `evening`, `night`, `overcast`.

### 2.10 Check my plan

> Check my plan for problems: overlapping furniture, furniture blocking a door or a window, furniture outside rooms, and walkways narrower than 80 cm. List every finding with the names of the pieces and propose a fix. Apply nothing until I say which fixes I want.

`scene.check_collisions` and `report.clearances` (with `minWalkwayMm: 800`). Add "apply the fixes" afterwards and it uses
`scene.move_objects`.

### 2.11 Walk through it

> Put the camera at eye height at the entrance door of the [apartment], looking into the flat, and render a picture. Then open the balcony door and the window in the living room and tell me whether I can walk from the door to the balcony without touching furniture.

`camera.set_state` (`mode: "firstPerson"`), `walk.get`, `walk.set`, `walk.toggle_door`, `walk.measure`,
`render.scene_image`. For a live walk-through on a big screen or TV use presenter mode by hand, see [PRESENTER.md](PRESENTER.md);
there are no agent tools that start it.

### 2.12 Export and print

> Export the plan of the ground floor as a PDF on A3 at 1:50 to [~/Documents/ground-floor.pdf], also save a top-down picture of the whole house with north at the top as a PNG to [~/Documents/house.png], and give me the room report and the bill of materials as tables.

`export.plan` (`format: "pdf"`, `paper`, `scale`), `camera.set_state` (`mode: "top"`, `yawDeg: 0`, so north is up), then `render.scene_image` (`preset: "top"` keeps that heading and fits the picture to the house; `path`), `report.rooms` and
`report.bom` (`format: "markdown"`). `export.obj` writes the 3D model as OBJ. Paths must be absolute (write the full home folder instead of `~`), the folder must exist,
and existing files are only replaced with `overwrite`.

### 2.13 Compare two layouts

> I have two Roomsmith tabs open, "[Layout A]" and "[Layout B]". Compare them: floor area, rooms, number of furniture pieces and wall length. Show them side by side and tell me which one leaves more free walking space in the living room.

`workspace.list`, `workspace.compare` (`show: true`), then `workspace.activate` and `report.clearances` for each project.
To try a second arrangement, ask: "Open a new tab and copy the furniture of the living room into it"
(`workspace.open`, `scene.transfer_objects`).

### 2.14 Improve a piece that already exists

> Look at the [armchair] in the living room. Render it close up, tell me what looks too simple or wrong, and improve it: add [thinner legs, a seam line, a cushion]. Keep its position and size.

`scene.list_objects`, `scene.get_object`, `render.scene_image` (an explicit `camera` from inside the room, see step 8 of the recipe), then
`furniture.update_definition` (change, add or remove single parts without losing placed copies).

### 2.15 Undo

> Undo your last change.

`history.undo`. Note that it undoes the most recent step of anyone, also your own manual edit.

## 3. Recipe for detailed furniture

**Ids.** Every result carries ids. Copy them exactly. A create call returns the new `id` (design id for
`furniture.create_definition`, placed instance id for `furniture.create_instance`): use "the `id` field from the result of call N".
List tools return `{"items":[...]}`: read the `id` from the row inside `items`.

Give this to a small model (or paste it as a prompt) whenever you want a piece built carefully. A condensed version is available as
a skill folder: [skills/roomsmith-furniture](skills/roomsmith-furniture/SKILL.md).

1. **Find the room and the wall.** Follow the list below, then go on with step 2.

   - Call `scene.list_objects` with `{"kind":"room"}`. Pick the room by `name`. Its `points` are the inner corners (mm). If `geometry.measure_distance` later gives a different gap than expected, shift the piece by the difference (the room outline is not always on the wall faces).
      Inner faces: west = smallest `x`, east = largest `x`, south = smallest `y`, north = largest `y`. Centre of the room =
      middle of those values.
   - Call `scene.list_objects` with `{"kind":"wall"}`. Pick the wall row by its `start` and `end` points, not by its position in
      the list or its direction: south wall = both `y` the lowest, north wall = both `y` the highest, west wall = both `x` the
      lowest, east wall = both `x` the highest. Read the wall list yourself, find the row, and COPY its `id` string literally into the next call (the `@N.path` placeholder syntax of test harnesses only works for whole fields, not for choosing a row).
      Wall points are centre lines. Never use them as positions: use the room's inner faces.
   - Place the piece with its back to the wall. D = the piece's depth (its `size.depth`), G = gap to the wall (10 mm, or 0 to touch).
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
2. **Measure.** Get the real width, depth and height in millimetres from me, from the product page or from the photo notes.
   If one size is missing, ask me. Never guess. Note the overall size as `{"width": X, "depth": Y, "height": Z}`.
3. **Choose the 4 to 8 main parts.** Walk around the piece in your head: top, sides, back, base, seat, backrest, doors,
   drawers. Each part is a box (`box`, or `panel` for thin plates), a rounded box (`cushion`), a `cylinder` or a `sphere`.
4. **Add small details.** Legs, feet, handles and knobs, trim strips, plinth, gaps between doors, cushions, a lamp shade.
   These make the difference between a plain block and a believable piece. Aim for 8 to 20 parts in total.
5. **Compute every part in local coordinates.** The origin is the centre of the footprint on the floor. `+X` is right,
   `+Y` is the back, `+Z` is up, so the front of the piece is on the `-Y` side. A part's `position` is the centre of its box,
   not a corner. A part's `size` is `width` along X, `depth` along Y, `height` along Z. For each part: centre = lower edge +
   half the size. Everything is whole millimetres. Parts stay inside the overall size, except small overhangs: a top panel up to 20 mm, knobs and handles up to about 40 mm.
6. **Choose the colours first.** Call `scene.list_objects` with `{"kind":"material"}` and REUSE an existing material by name
   (Oak, Walnut, Birch, White lacquer, Black metal, Chrome, ...). Only if none fits, call `material.create` (see 3.3).
   In components use the material name (simplest). Names are unique: if the name exists, `material.create` fails.
7. **Create the design.** Call `furniture.create_definition` with `name`, `category` (see 3.3), `size` and `components`. Keep the
   returned `id` (and `componentIds`). Then place it with `furniture.create_instance` (`definitionId`, `position` of the
   footprint centre in plan millimetres, `rotationDeg`). Rotation 0 puts the front towards south and the back towards north,
   so 0 stands the piece against a north wall, 180 against a south wall, 90 against a west wall and 270 against an east wall
   (counter-clockwise from above).
8. **Render a picture.** Look from inside the room with an explicit camera: `render.scene_image` with
   `{"camera":{"mode":"orbit","target":{"x":<piece x>,"y":<piece y>,"z":400},"distanceMm":3500,"yawDeg":<rotationDeg of the piece>,"pitchDeg":-20},"width":1024,"height":768}`.
   `distanceMm` 3500 suits rooms at least 4 m deep in the viewing direction; use about 2000 for smaller rooms (the camera must stay inside the room). To save the PNG add `"path"` (absolute file path, the folder must exist) and `"overwrite": true` (to replace an existing file). `yawDeg` is the direction the camera looks and equals the piece's `rotationDeg` (south wall 180, north 0, west 90, east 270;
   verified). Do not use `preset: "frame"` for a piece against a wall: for the south wall it shows only the grey outside
   of the wall. Use `frame` only away from walls. If the picture is too dark (a piece in a wall's shadow), call `light.set`
   with `{"mood":"daylight","applyMoodTime":true}` (or `timeMinutes`, `exposure`) and render again; compare with that second
   picture before you change any colour. To check a gap to a wall, call `geometry.measure_distance` with
   `{"from":{"id":"<instance id>"},"to":{"id":"<wall id>"}}` (each side is `{"id":...}` or `{"x":...,"y":...}`); read `distanceMm`.
9. **Look and fix.** Compare with the target: proportions, missing parts, parts floating or sunk into each other, parts
   sticking out of the footprint, wrong colour. Fix with `furniture.update_definition` (`updateComponents`, `addComponents`,
   `removeComponents`), render again and repeat until it looks right. Never delete and rebuild everything for a small change.

### 3.1 Worked example: a bedside table with a drawer and a handle

Target: 400 mm wide, 400 mm deep, 500 mm high. Four legs, a lower shelf, a drawer box with a front, a brass bar handle and a
top. Local coordinates, all millimetres.

| Part | Shape | Centre (x, y, z) | Size (width, depth, height) | Occupies |
|---|---|---|---|---|
| top | box | 0, 0, 485 | 400, 400, 30 | z 470 to 500 |
| leg_front_left | box | -180, -180, 165 | 40, 40, 330 | z 0 to 330 |
| leg_front_right | box | 180, -180, 165 | 40, 40, 330 | z 0 to 330 |
| leg_back_left | box | -180, 180, 165 | 40, 40, 330 | z 0 to 330 |
| leg_back_right | box | 180, 180, 165 | 40, 40, 330 | z 0 to 330 |
| lower_shelf | box | 0, 0, 150 | 320, 320, 18 | z 141 to 159, between the legs |
| drawer_box | box | 0, 0, 400 | 320, 340, 140 | z 330 to 470, between the legs |
| drawer_front | box | 0, -179, 400 | 300, 18, 120 | y -188 to -170, in front of the box |
| handle | box | 0, -194, 400 | 120, 12, 14 | y -200 to -188, still inside the footprint |

Step 6, the colours (three calls):

```json
{"tool":"material.create","arguments":{"name":"Oak Satin","color":"#B98B5A","pattern":"wood","finish":"satin","roughness":0.6}}
{"tool":"material.create","arguments":{"name":"Cream Lacquer","color":"#EFE8DA","finish":"matte"}}
{"tool":"material.create","arguments":{"name":"Brass Handle","color":"#B08D57","metallic":1,"roughness":0.35,"finish":"brushed"}}
```

Step 7, the design and placing:

```json
{"tool":"furniture.create_definition","arguments":{
  "name":"Bedside table with drawer",
  "category":"Bedroom",
  "tags":["bedside","drawer"],
  "size":{"width":400,"depth":400,"height":500},
  "components":[
    {"name":"top","shape":"box","position":{"x":0,"y":0,"z":485},"size":{"width":400,"depth":400,"height":30},"material":"Oak Satin"},
    {"name":"leg_front_left","shape":"box","position":{"x":-180,"y":-180,"z":165},"size":{"width":40,"depth":40,"height":330},"material":"Oak Satin"},
    {"name":"leg_front_right","shape":"box","position":{"x":180,"y":-180,"z":165},"size":{"width":40,"depth":40,"height":330},"material":"Oak Satin"},
    {"name":"leg_back_left","shape":"box","position":{"x":-180,"y":180,"z":165},"size":{"width":40,"depth":40,"height":330},"material":"Oak Satin"},
    {"name":"leg_back_right","shape":"box","position":{"x":180,"y":180,"z":165},"size":{"width":40,"depth":40,"height":330},"material":"Oak Satin"},
    {"name":"lower_shelf","shape":"box","position":{"x":0,"y":0,"z":150},"size":{"width":320,"depth":320,"height":18},"material":"Oak Satin"},
    {"name":"drawer_box","shape":"box","position":{"x":0,"y":0,"z":400},"size":{"width":320,"depth":340,"height":140},"material":"Oak Satin"},
    {"name":"drawer_front","shape":"box","position":{"x":0,"y":-179,"z":400},"size":{"width":300,"depth":18,"height":120},"material":"Cream Lacquer"},
    {"name":"handle","shape":"box","position":{"x":0,"y":-194,"z":400},"size":{"width":120,"depth":12,"height":14},"material":"Brass Handle"}
  ]}}
```

The answer contains `id`, the design id. Place it against the north wall (here the inner face of the wall is at y = 4000, and
the table stands 10 mm away from it, so its centre is at y = 4000 - 200 - 10 = 3790):

```json
{"tool":"furniture.create_instance","arguments":{
  "definitionId":"<id from the previous answer>",
  "position":{"x":2300,"y":3790},
  "rotationDeg":0,
  "name":"Bedside table left"}}
```

Step 8, the picture:

```json
{"tool":"render.scene_image","arguments":{"camera":{"mode":"orbit","target":{"x":2300,"y":3790,"z":250},"distanceMm":3500,"yawDeg":0,"pitchDeg":-20},"width":1024,"height":768}}
```

Step 9, a typical fix (the handle looks too thin and the drawer should be a different colour):

```json
{"tool":"furniture.update_definition","arguments":{
  "id":"<design id>",
  "updateComponents":[
    {"component":"handle","size":{"width":140,"depth":12,"height":20}},
    {"component":"drawer_front","material":"Oak Satin"}
  ]}}
```

Placed copies follow the change and keep their position.

For simple boxes you can start from a template: `furniture.create_from_template` with `template` `cabinet`, `table`,
`shelf`, `sofa` or `box`, then refine the parts with `furniture.update_definition`.

### 3.2 Typical sizes and parts (mm)

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

### 3.3 Colours and categories

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

`category` of `furniture.create_definition` is free text (default `Custom`). Always use one of these eight values so the
piece is grouped in the library: `Living`, `Bedroom`, `Kitchen`, `Bathroom`, `Office`, `Dining`, `Decor`, `Lighting`.
Pieces that fit none exactly:
* Sideboard, dresser, console, TV bench, bookshelf, storage in a living room: `Living`.
* Wardrobe, dresser, bed, nightstand, storage in a bedroom: `Bedroom`.
* Desk, office shelf, filing cabinet: `Office`. Dining table, chairs, buffet: `Dining`.
* Plants, vases, mirrors, rugs, pictures: `Decor`. Lamps: `Lighting`.

### 3.4 Worked example: a TV bench against the north wall

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

## 4. Common mistakes

* **Wrong axis.** The front of a piece is on the `-Y` side, the back on `+Y`. Height is `Z`, never `Y`. In `size`, `width`
  is X, `depth` is Y, `height` is Z.
* **Centre, not corner.** A part's `position` is the centre of its box. A 40 mm leg that stands on the floor has its centre
  at `z = 20`, not 0.
* **Wrong unit.** Everything is whole millimetres. 90 cm is `900`. Decimals such as `487.5` are rejected, so pick part sizes
  that give whole numbers.
* **Footprint centre.** `furniture.create_instance` `position` is the centre of the footprint, not a corner. A wall's
  centre line is not its surface: take the wall thickness into account.
* **Unknown material.** A material name must exist (`material.create` first, or a name from `scene.list_objects` with
  `kind: "material"`).
* **Taken material name.** Names are unique. Reuse the existing material ("Oak" already exists) or pick another name.
* **`preset: "frame"` against a wall.** Use an explicit camera from inside the room, `yawDeg` = the piece's `rotationDeg`.
* **Wrong `rotationDeg` for a wall.** South 180, north 0, west 90, east 270.
* **Bare ids in `geometry.measure_distance`.** Use `{"id": ...}`.
* **Duplicate part names.** Every part name must be unique inside one design.
* **Forgetting to look.** Always render and look before saying "done".
