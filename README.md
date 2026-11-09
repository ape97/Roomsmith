<p align="center">
  <img src="docs/images/icon.png" alt="Roomsmith icon" width="128">
</p>

<h1 align="center">Roomsmith</h1>

<p align="center">A native macOS floor planner you can simply talk to: tell your AI "build me a two-room flat" or "I want
this sofa", and it draws the walls, rooms and furniture, part by part and exact to the millimetre, while you watch in 2D
and 3D.</p>

<p align="center">
  <a href="#requirements"><img src="https://img.shields.io/badge/macOS-26%2B-black?logo=apple" alt="macOS 26+"></a>
  <a href="docs/DEVELOPMENT.md"><img src="https://img.shields.io/badge/Swift%206-SwiftUI%20%2B%20RealityKit-orange?logo=swift" alt="Swift 6, SwiftUI, RealityKit"></a>
  <a href="docs/MCP_API.md"><img src="https://img.shields.io/badge/MCP-120%20agent%20tools-6E56CF" alt="MCP: 120 agent tools"></a>
  <a href="docs/AGENT_PROMPTS.md"><img src="https://img.shields.io/badge/prompt%20kit-ready%20to%20paste-2E8B57" alt="Prompt kit"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue" alt="License: MIT"></a>
  <a href="#ai-assisted-development"><img src="https://img.shields.io/badge/built%20with-AI%20assistance-8A2BE2" alt="AI-assisted"></a>
</p>

> [!NOTE]
> This app was developed with AI assistance. See [AI-assisted development](#ai-assisted-development).

<p align="center">
  <img src="docs/images/hero-aerial.png" alt="Aerial view of a furnished two-room apartment with living room and kitchen, bedroom, hallway and bathroom" width="860">
</p>

## Your AI builds it, you decide

Roomsmith is made to be driven by an AI assistant. Connect Claude Code (or any other MCP client), open a project and
write what you want in plain words:

> *"Build me a two-room flat, 9.5 × 7 m, with an open kitchen, a bedroom, a small hallway and a bathroom."*
>
> *"I want this sofa: [link to the product page]. Build it with its real size and colours and put it against the north wall."*
>
> *"Make it an evening scene, switch the lamps on and render the living room from the door."*

The AI works on **the same open project** as you, through **120 MCP tools**: it draws walls, cuts in doors and windows,
finds the rooms, lays floors, builds furniture from individual parts (legs, frames, drawers, handles, cushions), picks
materials, adds lamps that really glow, sets the light and renders pictures to check its own work. Every change shows up live in
the plan and in 3D, you can keep dragging things by hand at the same time, and **every AI change is exactly one undo step**.
Reading is always allowed; writing has to be switched on in the **Agents** panel and can be switched off at any moment.

<p align="center">
  <img src="docs/images/ai-build.gif" alt="An empty scene fills step by step: outer walls, inner walls, doors and windows, floors, then the furniture room by room, finally materials and styling" width="720">
</p>

<sub>The flat being built through the agent tools, one batch of tool calls after another. The animation starts on an empty
scene; it is a scripted replay of the calls an agent makes (`scripts/make-media.py`), rendered by the app itself.</sub>

### Detailed furniture with the prompt kit

The built-in library covers the basics; the pieces that make a home yours are modelled **by you and your AI**, from a
description, a photo or a product link. The [prompt kit](docs/AGENT_PROMPTS.md) gives you ready-to-paste prompts and a
step-by-step furniture recipe: real sizes in millimetres, one part per component, materials, a rendered check picture,
then the fix. The recipe is written so plainly that **a small, fast model is enough**; the same rules ship as a skill you
can drop into your assistant ([roomsmith-furniture/SKILL.md](docs/skills/roomsmith-furniture/SKILL.md)).

<p align="center">
  <img src="docs/images/prompt-kit-furniture.png" alt="A walnut sideboard with three drawers and a birch writing desk with a drawer pedestal, both defined by the agent from a prompt" width="720">
</p>

<sub>A walnut sideboard and a birch writing desk with a drawer pedestal, each defined part by part from a prompt (the exact
tool input is in `scripts/media-prompt-kit.json`).</sub>

Where to start:

| Page | What it gives you |
|---|---|
| [docs/AGENT_PROMPTS.md](docs/AGENT_PROMPTS.md) | Prompt kit: starter rules, 15 example prompts (furnish a room, "I want this product", piece from a photo, lamps, materials, evening mood, plan check, walk-through, export), the furniture recipe with worked examples |
| [docs/skills/roomsmith-furniture/SKILL.md](docs/skills/roomsmith-furniture/SKILL.md) | The furniture recipe as a skill for your AI client |
| [docs/AGENT_GUIDE.md](docs/AGENT_GUIDE.md) | Connecting Claude Code, the safe list-get-change workflow, things to know |
| [docs/MCP_API.md](docs/MCP_API.md) | All 120 tools with parameters, results and error codes |

Roomsmith itself never fetches web pages: for "I want this product" your AI client reads the page and the photos, and
Roomsmith receives only the numbers it builds from.

## In action

### Orbit around the plan

<p align="center">
  <img src="docs/images/orbit.gif" alt="The 3D camera circles the furnished demo apartment once" width="720">
</p>

Drag, pinch and rotate on the trackpad to fly around the model; walls, floors, furniture and the sun shadows are
rendered live with RealityKit.

### Walk through it

<p align="center">
  <img src="docs/images/walkthrough.gif" alt="First-person walk at eye height past the kitchen and the dining table into the living room" width="720">
</p>

First person at eye height, at 1:1 scale, with collisions: past the kitchen and the dining table into the living room.

### Switch camera modes

<p align="center">
  <img src="docs/images/camera-modes.gif" alt="The view switches from eye height in the living room to a top view, an aerial view and first person" width="640">
</p>

One click switches between orbit, free flight, top view, aerial view and first person; saved views bring you back.

### From day to night

<p align="center">
  <img src="docs/images/day-to-night.gif" alt="The sun moves across the apartment and its shadows wander, then the scene turns to evening and to night with the lamps lit" width="640">
</p>

Date, time, latitude and north give the real sun position and its shadows; moods switch to evening and night.

### Lamps that glow

<p align="center">
  <img src="docs/images/lamps.gif" alt="At night the lamps of the apartment switch on one after another" width="720">
</p>

Lamps are part of the furniture design. At night they light the rooms one after another.

### Doors, drawers and windows that move

<p align="center">
  <img src="docs/images/doors-states.gif" alt="The fridge door opens, the wardrobe doors swing open, a drawer of the chest slides out and the room door swings shut" width="640">
</p>

Furniture states (door open, drawer out) are animated: the fridge, the wardrobe, a drawer and the room door.

### Try materials

<p align="center">
  <img src="docs/images/materials.gif" alt="The living room cycles through floor tiles, a darker wood floor, green and terracotta walls, and brown and green sofa covers" width="640">
</p>

Floor, walls and upholstery change in place: tiles, wood, wall colours, sofa fabrics and leather.

<sub>All animations and pictures are rendered by the app itself from the demo project; nothing is a mock-up.</sub>

## Features

### Plan and model

- **Millimetre-exact model.** Every length is stored as an integer number of millimetres. Areas, volumes and dimension
  chains are computed exactly and shown in m², cm or mm; nothing drifts through floating-point rounding.
- **Walls, rooms and levels.** Draw walls with the wall tool; rooms are found from closed walls or drawn by hand, with
  their area. Several levels per project.
- **2D plan and 3D view side by side.** Plan and 3D view stacked or side by side, either one alone, or the 3D view
  detached into its own window, for example on a second display.
- **Furniture seen from above.** In the plan every piece is drawn as its real top view with its name, not as a box.
- **Direct editing in both views.** Picking, a move and rotate gizmo, grid, wall and angle snapping, furniture that docks
  flush against walls and other furniture (also when dragged in 3D), collision warnings (with a per-piece "Allow
  overlap"), a hand tool for looking without editing, and full undo.
- **Drag and drop.** Drag furniture from the library into the plan or straight into the 3D view.
- **Several projects at once.** Open projects as tabs, compare two side by side with their figures, and drag or copy
  furniture from one project into another.

### 3D, light and walking

- **3D camera modes.** Orbit, free flight, top view, aerial view and first person, plus saved views you can jump back to.
- **See-through walls.** Make walls translucent or hide them to look into rooms from any angle.
- **Light and sun.** Set date, time, latitude and north to get the sun and its shadows, pick a mood (daylight, evening,
  night, overcast), adjust the exposure, and put lamps into furniture designs. Lamp brightness is an estimate and lamps
  cast no shadows.
- **3D ruler.** Pick the ruler and click two points on walls, floors or furniture in the 3D view to read the distance and
  its east, north and up parts. Tools that only work in the plan are greyed out in the 3D view.
- **Walk mode.** Walk through the plan at eye level in 1:1, with collisions, doors you can open and close, and crouching.
  Body height, eye height, body radius, walking speeds and the field of view (standard or calibrated to your screen) are
  adjustable; an agent tool measures distances from the walker's view.

### Furniture

- **Furniture builder.** Build pieces from parts, import USDZ models, group them, save configurations, and define states
  (door open, drawer out) with animations.
- **Doors, windows and materials in detail.** Opening styles, handles, frame width, mullions and glass types; material
  presets and procedural patterns (tiles, wood, fabric, leather, brushed metal).
- **Your own furniture library.** Save designs in a library that belongs to no project, with separate sections for your
  own, planned, AI-made and standard furniture; search it and place entries into any project.
- **Furniture from photos.** Drop up to six photos and give one real size: Roomsmith analyses them on your Mac and
  approximates the piece over five builder templates. It is an approximation, not a 3D scan (see "Known limits" in
  [docs/STATUS.md](docs/STATUS.md)); for detail, refine it with your AI and the prompt kit.

### Presenter mode and AirPlay

Show the plan, the 3D view or both side by side on a TV or projector, controlled from the Mac (View → Present…, ⌥⌘P,
or the **Present** toolbar button):

- **Live window on an extra display (recommended).** Connect the Apple TV as a separate display (Control Center →
  Screen Mirroring → Use as Separate Display) or plug in a screen. Roomsmith picks the external display (never the Mac's
  own screen) and opens a borderless presenter window there, also by itself when a display is connected while the panel
  is open. This uses the system's mirroring path and is real time. Esc closes it. Arrange the TV in System Settings →
  Displays so that it touches the Mac display only at a corner; macOS lets the pointer wander onto a second display.
- **AirPlay video (2–4 s delay).** Without a separate display, Roomsmith encodes the picture as an H.264 video stream,
  serves it on your local network and plays it to the AirPlay receiver you pick in the route picker. The real pointer is
  never part of this video; a laser ring can mark the spot under your pointer instead. Nothing listens before you press
  Start, the stream address carries an unguessable token and the server stops when you stop.
- **What the viewer sees.** The plan pane always shows the whole plan; the 3D pane follows the camera of the live view
  and updates when the camera, the project or the view settings change.
- **Honest status.** The stream pipeline is covered by unit and loopback tests; the pass on a real Apple TV (latency,
  local network prompt, pointer behaviour) has not been verified yet. The presenter is operated by hand only: there are
  no agent tools for it. Details: [docs/PRESENTER.md](docs/PRESENTER.md).

### Output

- **Exact exports.** The plan as true-scale SVG and PDF (1:20 to 1:200, with scale bar, title and paper size), PNG
  renders of the 3D view up to 4K, OBJ meshes, plus room reports, bill of materials and clearance checks as CSV or
  Markdown.

### App

- **AI agent API.** 120 MCP tools in 18 families let Claude Code (or any MCP client) read and change the open project:
  walls, rooms, furniture, materials, light, camera, renders, reports, the library and the workspace. Every agent change
  is one undo step named "Agent: …"; [docs/PARITY.md](docs/PARITY.md) tracks that every feature is reachable by hand and
  by agent.
- **Trackpad first.** Pinch to zoom around the pointer, two-finger pan and orbit, rotate gestures for the selection,
  smart zoom to frame, all with momentum.
- **Everything optional.** Sidebar, inspector, status bar, plan, 3D view and each overlay can be shown or hidden one by one.
- **Open, readable file format.** A project is a folder `Name.roomsmith/` with a Markdown file `project.md` that people and
  AI models can read, plus `assets/` for models and textures and `backups/` for automatic backups.
- **Fast and safe.** Autosave, rolling backups and crash recovery; the last session reopens with its tabs. Numbers below
  under [Performance](#performance).

## Screenshots

<p align="center">
  <img src="docs/images/app-dark.png" alt="Roomsmith with the object list, the 2D plan and the 3D view (dark appearance)" width="420">
  <img src="docs/images/app-light.png" alt="Roomsmith with the object list, the 2D plan and the 3D view (light appearance)" width="420">
</p>

<table>
  <tr>
    <td align="center"><img src="docs/images/plan-dimensions.png" width="420"><br>Plan with room areas and dimension chains</td>
    <td align="center"><img src="docs/images/plan-furnished.png" width="420"><br>Furnished plan, every piece as its real top view</td>
  </tr>
  <tr>
    <td align="center"><img src="docs/images/interior.png" width="420"><br>Inside the living room</td>
    <td align="center"><img src="docs/images/walls-transparent.png" width="420"><br>Translucent walls</td>
  </tr>
  <tr>
    <td align="center"><img src="docs/images/doors-windows.png" width="420"><br>Doors and windows: style, handle, glazing bars, glass</td>
    <td align="center"><img src="docs/images/evening.png" width="420"><br>Evening light with the lamps on</td>
  </tr>
  <tr>
    <td align="center"><img src="docs/images/night.png" width="420"><br>Night: the lamps light the rooms</td>
    <td align="center"><img src="docs/images/library.png" width="420"><br>Library with own, planned, AI and standard furniture</td>
  </tr>
  <tr>
    <td align="center"><img src="docs/images/workspace.png" width="420"><br>Two projects in tabs, compared side by side</td>
    <td align="center"><img src="docs/images/photo-sheet.png" width="420"><br>Furniture from photos, measured from one real size</td>
  </tr>
  <tr>
    <td align="center"><img src="docs/images/settings-walk.png" width="300"><br>Walk settings: body, field of view, speeds</td>
    <td align="center"><img src="docs/images/plan.png" width="420"><br>Plan export, 1:50 on A3</td>
  </tr>
  <tr>
    <td align="center"><img src="docs/images/inspector.png" width="300"><br>Inspector: position, size, design state, lamps and product info</td>
    <td align="center"><img src="docs/images/agent-panel.png" width="420"><br>Agent panel: one setup command, write access you can switch off</td>
  </tr>
  <tr>
    <td align="center" colspan="2"><img src="docs/images/presenter-airplay.png" width="640"><br>Presenter: live window on a separate display, or AirPlay video for plan, 3D or side by side</td>
  </tr>
</table>

### Room by room

<table>
  <tr>
    <td align="center"><img src="docs/images/gallery-living.png" width="420"><br>Living room</td>
    <td align="center"><img src="docs/images/gallery-dining.png" width="420"><br>Dining table and kitchen</td>
  </tr>
  <tr>
    <td align="center"><img src="docs/images/gallery-kitchen.png" width="420"><br>Kitchen</td>
    <td align="center"><img src="docs/images/gallery-bedroom.png" width="420"><br>Bedroom</td>
  </tr>
  <tr>
    <td align="center"><img src="docs/images/gallery-bath.png" width="420"><br>Bathroom from above</td>
    <td align="center"><img src="docs/images/gallery-evening-living.png" width="420"><br>Living room in the evening</td>
  </tr>
  <tr>
    <td align="center"><img src="docs/images/gallery-night-bedroom.png" width="420"><br>Bedroom at night, bedside lamps on</td>
    <td></td>
  </tr>
</table>

The pictures show `Examples/Demo Apartment.roomsmith`, which you can open yourself. It is generated through the agent API
by `scripts/make-demo.py`; `scripts/make-media.py` refines it (doors, windows, materials, lamps) and renders the pictures
and GIFs with the app's own renderer (see [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md#screenshots-and-gifs)). The 3D ruler
and the presenter window are live-only and have no picture.

## Requirements

- macOS 26 or later on Apple silicon (arm64)
- For building from source: Xcode 26 (Swift 6)
- For the AI workflow: an MCP client such as Claude Code

## Installation

1. Download `Roomsmith-<version>.zip` from the [latest release](../../releases/latest) and unzip it.
2. Move **Roomsmith.app** to `/Applications`.
3. Open it. The app is free and ad-hoc signed, not notarized by Apple, so macOS blocks the first launch. On macOS 26,
   Control-click → **Open** shows the same warning; instead open **System Settings → Privacy & Security**, scroll down and
   click **Open Anyway**. Alternatively, in Terminal: `xattr -dr com.apple.quarantine /Applications/Roomsmith.app`

To uninstall, quit Roomsmith and move it to the Trash. Projects stay wherever you saved them; the shared furniture
library is kept in Roomsmith's Application Support folder.

## Build from source

```sh
git clone https://github.com/ape97/Roomsmith.git && cd Roomsmith
./scripts/check.sh    # build of all targets + tests -> RESULT: GREEN
./scripts/deploy.sh   # build the release bundle, install to /Applications, start
```

`scripts/bundle.sh` alone builds `build/Roomsmith.app` (app plus the `roomsmith-mcp` helper, ad-hoc signed) without
installing it. No Apple developer account is needed. Targets, scripts, signing and releases are described in
[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## Usage

- **New project:** File → New, then draw walls with the wall tool; rooms are found from closed walls or drawn by hand.
- **Furniture:** drag a piece from the library on the left into the plan or the 3D view, then move it with the mouse,
  the arrow keys or the gizmo. In 3D select a piece first, then drag it over the floor; it stops flush at walls and
  other furniture, and pulling on goes through (⌥ switches that off). Rugs and pieces marked "Allow overlap" in the
  inspector may overlap anything. Type exact sizes and positions in the inspector.
- **Views:** View → Plan, 3D or both (⌘1, ⌘2, ⌘3). The camera buttons above the 3D view switch between Orbit, Free,
  Top, Aerial and First person; in first person walk with W A S D, in Free fly with W A S D and Q E (down, up).
- **Present:** View → Present… (⌥⌘P) opens the presenter panel.
- **Export:** File → Export for the plan (SVG, PDF, PNG), the 3D view as an image, OBJ and reports.
- **Trackpad and mouse reference:** [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md#trackpad-and-mouse).

## Connecting your AI

Roomsmith ships a small MCP server, `roomsmith-mcp`, that talks to the running app. Open the **Agents** panel in
Roomsmith, copy the setup command and run it once:

```sh
claude mcp add roomsmith -- /Applications/Roomsmith.app/Contents/Helpers/roomsmith-mcp
```

Then start Claude Code and ask, for example, *"put a 200 × 90 cm desk under the window in the bedroom, 10 cm from the
wall"* or *"render the living room from the door and tell me if the sofa blocks the walkway"*. Switch on "Allow agents to
change the project" in the Agents panel when the AI should write. Any other MCP client works the same way with the same
helper. Full setup: [docs/AGENT_GUIDE.md](docs/AGENT_GUIDE.md); prompts: [docs/AGENT_PROMPTS.md](docs/AGENT_PROMPTS.md).

## File format

A project is a folder that Finder shows as one document:

```
Demo Apartment.roomsmith/
├── project.md     # the whole model as Markdown tables, in millimetres
├── assets/        # imported models and textures
└── backups/       # rolling automatic backups
```

The format is described in [docs/FILE_FORMAT.md](docs/FILE_FORMAT.md).

## Performance

Measured on a generated stress project (110 walls, 48 rooms, 1000 pieces of furniture, 20 groups) in a release build on
an Apple M4 Pro:

| Measurement | Value |
|---|---:|
| Load the 1000-piece project | 7.6 ms |
| Save it | 2.2 ms |
| Move one piece (diff, validation, undo record, event), median | 0.51 ms |
| Collision check after moving one piece | 0.45 ms |
| 3D frame, demo apartment, 1920 × 1080, median | 3.0 ms (about 330 fps) |
| 3D frame, 1000-piece project, 1920 × 1080, median | 50 ms (about 20 fps) |
| Memory with plan and 3D view open (stress project) | 300 MB |

Dragging a piece in a 1000-piece project costs far less than one frame at 120 Hz; a typical apartment draws well inside
120 Hz. The slow paths are whole-project exports (SVG plan, OBJ of all meshes), which run once per export. Method and all
numbers: [docs/PERFORMANCE.md](docs/PERFORMANCE.md).

## Privacy

Roomsmith works offline and has no telemetry. The agent connection is a Unix socket in your user folder, protected by a
token, and only reachable by programs you start yourself. Photo analysis runs on your Mac. The only network use is the
presenter's AirPlay video stream: while you present that way, the picture is served on your local network (macOS asks for
Local Network access once), and nothing listens before you press Start.

## Documentation

| Document | Contents |
|---|---|
| [docs/AGENT_PROMPTS.md](docs/AGENT_PROMPTS.md) | Prompt kit: build furniture, rooms and lighting by talking to your AI |
| [docs/skills/roomsmith-furniture/SKILL.md](docs/skills/roomsmith-furniture/SKILL.md) | Furniture skill for your AI client |
| [docs/AGENT_GUIDE.md](docs/AGENT_GUIDE.md) | Using Roomsmith from Claude Code |
| [docs/MCP_API.md](docs/MCP_API.md) | Every agent tool with parameters and results |
| [docs/PRESENTER.md](docs/PRESENTER.md) | Presenter mode and AirPlay |
| [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) | Build, scripts, targets, trackpad reference, panels, releasing |
| [docs/FILE_FORMAT.md](docs/FILE_FORMAT.md) | The `.roomsmith` format |
| [docs/PERFORMANCE.md](docs/PERFORMANCE.md) | Benchmark and measured numbers |
| [docs/PARITY.md](docs/PARITY.md) | Every feature reachable by hand and by agent |
| [docs/STATUS.md](docs/STATUS.md) | Current state and known limits |
| [docs/README.md](docs/README.md) | Index of all documentation |

## AI-assisted development

Roomsmith was built with the help of an AI coding assistant: code, comments, documentation and the demo pictures were
written in collaboration with AI. Every change is built and tested with `scripts/check.sh`: a build of all targets plus
1100 core tests and 56 app tests in the last full run. Issues and pull requests are welcome.

## License

MIT, see [LICENSE](LICENSE).
