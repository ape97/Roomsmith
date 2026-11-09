#!/usr/bin/env python3
"""Render the README pictures and GIFs of the Demo Apartment through the Roomsmith agent API (MCP).

Usage: make-media.py <path-to-roomsmith-mcp> <images-folder> [--work <folder>] [--only <name>[,<name>...]] [--keep]

The app must already be running (started with `open -g -j -n`, test mode, own ROOMSMITH_SOCKET and
ROOMSMITH_SUPPORT_DIR; see docs/DEVELOPMENT.md, "Screenshots and GIFs"). The script

1. builds the demo project with make-demo.py (it replaces the open project),
2. refines it with the newer features: styled doors and windows (panel doors with lever handles, tilt-and-turn windows
   with glazing bars, frosted bathroom glass), material presets (oak floor, tiles, striped wallpaper), lamp emitters,
3. saves the refined project as <work>/refined/Demo Apartment.roomsmith (use it as ROOMSMITH_OPEN for window pictures;
   the default work folder is a temporary folder that is removed at the end, so pass --work or --keep to keep it),
4. renders every picture with `render.scene_image` and a `camera`, and every GIF as a frame folder that
   `scripts/gif.sh` turns into a palette GIF.

Pictures: hero-aerial, interior, walls-transparent (daylight), evening and night (lamps on), doors-windows (eye level),
gallery-living/-kitchen/-bedroom/-bath/-dining, gallery-evening-living, gallery-night-bedroom, plan-dimensions,
plan-furnished (plan with the furniture drawn in, from render.plan_image) and prompt-kit-furniture (a sideboard and a
desk the agent defines from a prompt, scripts/media-prompt-kit.json).
GIFs: orbit, walkthrough, ai-build (the flat gets built and furnished step by step), day-to-night, lamps, doors-states
(doors and windows opening), materials (sofa fabrics) and camera-modes (orbit, first person, top).
Left out on purpose: the 3D ruler (live overlay only, no offscreen render). Window pictures come from
scripts/make-windows.sh, not from this script.
Nothing here is a mock-up: all pixels come from the app's own renderer. `--only` renders just the named pictures or
GIFs (for example `--only doors-windows,walkthrough`); the project is always rebuilt first.
"""
import argparse
import importlib.util
import json
import math
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))


def _load_demo():
    spec = importlib.util.spec_from_file_location("make_demo", os.path.join(HERE, "make-demo.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


demo = _load_demo()
uid, pt = demo.uid, demo.pt

# ---------------------------------------------------------------- refinement

# opening name -> update_opening arguments (style, handle, glazing bars, glass)
DOORS = {
    "Entrance door": {"style": "panel4", "handle": "bar"},
    "Door hallway - living room": {"style": "panel2", "handle": "lever"},
    "Door hallway - bathroom": {"style": "panel2", "handle": "lever"},
    "Door hallway - bedroom": {"style": "panel4", "handle": "lever"},
}
WINDOWS = {
    "Living room window south 1": {"style": "tiltTurn2", "handle": "lever", "mullionCols": 2, "mullionRows": 1},
    "Living room window south 2": {"style": "tiltTurn2", "handle": "lever", "mullionCols": 2, "mullionRows": 1},
    "Dining window west": {"style": "tiltTurn2", "handle": "lever", "mullionCols": 2, "mullionRows": 1},
    "Kitchen window": {"style": "tiltTurn1", "handle": "lever"},
    "Living room window north": {"style": "tiltTurn2", "handle": "lever", "mullionCols": 2, "mullionRows": 1},
    "Bedroom window north": {"style": "tiltTurn1", "handle": "lever", "mullionRows": 1},
    "Bedroom window east": {"style": "tiltTurn2", "handle": "lever", "mullionCols": 1, "mullionRows": 1},
    "Bathroom window": {"style": "tiltTurn1", "handle": "lever", "glass": "frosted"},
}
FRAME = "Frame white"

# lamp name -> light.set_emitter arguments (position in the design's space; omitted = top of the piece)
# Warm white (3400 K) and modest lumens: the evening and night pictures raise the exposure so the dark rooms stay readable,
# which brightens the lamps as well.
LAMPS = {
    "Floor lamp": {"name": "Floor lamp", "kind": "point", "positionMm": {"x": 0, "y": 0, "z": 1450}, "kelvin": 3400,
                   "lumens": 350, "rangeMm": 7000},
    "Table lamp": {"name": "Table lamp", "kind": "point", "positionMm": {"x": 0, "y": 0, "z": 330}, "kelvin": 3400,
                   "lumens": 220, "rangeMm": 5000},
    "Pendant lamp": {"name": "Pendant", "kind": "point", "positionMm": {"x": 0, "y": 0, "z": 165}, "kelvin": 3400,
                     "lumens": 250, "rangeMm": 6000},
}
# light.set for the lamp-lit pictures. Both use the night sky: its deep blue reads as dusk through the windows, while the
# evening mood's orange sky tinted every wall. Evening is the brighter of the two.
EVENING_LIGHT = {"mood": "night", "applyMoodTime": True, "exposure": 3.0}
NIGHT_LIGHT = {"mood": "night", "applyMoodTime": True, "exposure": 2.6}


def refine(c):
    """Applies styled openings, material presets and lamp emitters to the freshly built demo project."""
    c.call("material.create", id=uid("mat " + FRAME), name=FRAME, color="#F7F7F3", roughness=0.4)
    steps = []
    for name, extra in {**DOORS, **WINDOWS}.items():
        steps.append(("geometry.update_opening", dict(id=uid("opening " + name), frameMaterial=FRAME, **extra)))
    c.batch(steps)

    # material presets: they replace roughness, finish and pattern; the colour only changes when the preset has one
    c.batch([("material.apply_preset", {"id": uid("mat Oak parquet"), "preset": "wood-oak"}),
             ("material.apply_preset", {"id": uid("mat Light tiles"), "preset": "tiles-white"}),
             ("material.apply_preset", {"id": uid("mat Hallway stone"), "preset": "tiles-anthracite"}),
             ("material.apply_preset", {"id": uid("mat Accent sage"), "preset": "wallpaper-stripes"})])
    # the wallpaper wall behind the bed keeps its sage green
    c.call("material.update", id=uid("mat Accent sage"), color="#B8C6AE", color2="#97AB8E")

    # lamp emitters for the lamps of the demo project (all pieces of a design follow)
    furniture = c.call("scene.list_objects", kind="furniture", limit=200)["items"]
    lamps = {}
    for item in furniture:
        if item["definition"] in LAMPS:
            lamps.setdefault(item["definition"], []).append(item)
    for design, args in LAMPS.items():
        if design not in lamps:
            sys.exit("demo project has no '%s'" % design)
        c.call("light.set_emitter", definitionId=lamps[design][0]["definitionId"], **args)
    return [i["id"] for items in lamps.values() for i in items]


def lamps_on(c, ids, on):
    c.batch([("light.toggle", {"id": i, "on": on}) for i in ids])


# ---------------------------------------------------------------- cameras

AERIAL = {"mode": "orbit", "target": dict(pt(4630, 3380), z=0), "distanceMm": 15000, "yawDeg": 20, "pitchDeg": -50,
          "fovDeg": 45}
LIVING = {"mode": "orbit", "target": dict(pt(1800, 3300), z=800), "distanceMm": 4800, "yawDeg": 120, "pitchDeg": -18,
          "fovDeg": 65}
# Evening: the flat seen from the south-west with the lamps on; night: from the north, one lamp lights the living room.
EVENING = {"mode": "orbit", "target": dict(pt(4630, 3380), z=0), "distanceMm": 12500, "yawDeg": -25, "pitchDeg": -55,
           "fovDeg": 45}
NIGHT = {"mode": "orbit", "target": dict(pt(4630, 3380), z=0), "distanceMm": 12500, "yawDeg": 200, "pitchDeg": -55,
         "fovDeg": 45}
# Eye level in the living room, looking at the south windows (glazing bars, tilt-and-turn handles) and a panel door.
DOORS_WINDOWS = {"mode": "firstPerson", "target": dict(pt(2500, 3600), z=1500), "yawDeg": 195, "pitchDeg": -4,
                 "fovDeg": 70}

SIZE = (1600, 1000)
GIF_SIZE = (720, 450)


def render(c, path, camera, size=SIZE, **extra):
    c.call("render.scene_image", path=path, overwrite=True, width=size[0], height=size[1], camera=camera, **extra)


def ease(t):
    return t * t * (3 - 2 * t)


def lerp(a, b, t):
    return a + (b - a) * t


def walk_path(frames):
    """Eye positions and headings of the walkthrough: from the kitchen end past the dining table to the sofa and windows.

    Yaw 0 looks north (+Y) and grows counter-clockwise, so 90 looks west and 180 south. The picture is rendered offline,
    where doors always stay closed (doors only open in the live walk view), so the path stays inside the open living room.
    """
    # (x, y, yaw) key points; the eye walks straight between them with eased turns
    keys = [(5200, 5600, 85), (3900, 5000, 100), (3000, 4000, 150), (2600, 3000, 185), (2600, 2500, 180)]
    seg = [math.dist(keys[i][:2], keys[i + 1][:2]) for i in range(len(keys) - 1)]
    total = sum(seg)
    out = []
    for f in range(frames):
        d = f / (frames - 1) * total
        i = 0
        while i < len(seg) - 1 and d > seg[i]:
            d -= seg[i]
            i += 1
        t = min(max(d / seg[i], 0), 1)
        a, b = keys[i], keys[i + 1]
        out.append((lerp(a[0], b[0], t), lerp(a[1], b[1], t), lerp(a[2], b[2], ease(t))))
    return out


def make_gif(frames_dir, gif, fps):
    # textured 3D frames (parquet, wallpaper) bloat a dithered palette GIF, so no dithering and 128 colours
    env = dict(os.environ, GIF_COLORS="128", GIF_DITHER="none")
    subprocess.run([os.path.join(HERE, "gif.sh"), frames_dir, gif, str(fps), str(GIF_SIZE[0])], check=True, env=env)
    if os.path.getsize(gif) > 4_000_000:  # still too big for a README: fewer colours and a smaller width
        env["GIF_COLORS"] = "64"
        subprocess.run([os.path.join(HERE, "gif.sh"), frames_dir, gif, str(fps), "640"], check=True, env=env)

# ---------------------------------------------------------------- frame engine
# A GIF is a list of "specs" (a, b, alpha): a and b are (state, camera) pairs. A spec with b renders both and dissolves them
# with ffmpeg (alpha 0 = a, 1 = b), which softens the hard changes of the renderer (mood, lamps, materials, cuts).


def blend(a, b, alpha, out):
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", a, "-i", b, "-filter_complex",
                    "[0][1]blend=all_mode=normal:all_opacity=%.3f" % alpha, "-frames:v", "1", out], check=True)


def render_specs(c, frames_dir, specs, apply_state, size=GIF_SIZE):
    shutil.rmtree(frames_dir, ignore_errors=True)
    os.makedirs(frames_dir)
    cur = [None]

    def show(pair, path):
        if cur[0] != pair[0]:
            apply_state(c, pair[0])
            cur[0] = pair[0]
        render(c, path, pair[1], size)

    for f, (a, b, alpha) in enumerate(specs):
        path = os.path.join(frames_dir, "f%03d.png" % f)
        if b is None:
            show(a, path)
        else:
            show(a, path + ".a.png")
            show(b, path + ".b.png")
            blend(path + ".a.png", path + ".b.png", alpha, path)
            os.remove(path + ".a.png")
            os.remove(path + ".b.png")


def dissolve(a, b, n=3):
    """n blended specs from pair a to pair b."""
    return [(a, b, ease((k + 1) / (n + 1))) for k in range(n)]


def cam_sweep(base, n, **ends):
    """n cameras from `base` to the given end values (yawDeg=..., distanceMm=...), eased."""
    out = []
    for k in range(n):
        t = ease(k / max(n - 1, 1))
        cam = dict(base)
        for key, end in ends.items():
            cam[key] = lerp(base[key], end, t)
        cam["distanceMm"] = round(cam["distanceMm"])
        out.append(cam)
    return out


def lamp_groups(c):
    """Lamp pieces by design, in the order floor lamp, pendants, table lamps."""
    groups = {d: [] for d in LAMPS}
    for item in c.call("scene.list_objects", kind="furniture", limit=200)["items"]:
        if item["definition"] in groups:
            groups[item["definition"]].append(item["id"])
    return list(groups.values())


def piece(c, name):
    for item in c.call("scene.list_objects", kind="furniture", limit=200)["items"]:
        if item["name"] == name:
            return item
    sys.exit("demo project has no '%s'" % name)


# ---------------------------------------------------------------- more cameras

# gallery: the same flat from other angles
SOFA = {"mode": "orbit", "target": dict(pt(3200, 1700), z=500), "distanceMm": 3200, "yawDeg": 270, "pitchDeg": -18, "fovDeg": 55}
KITCHEN = {"mode": "orbit", "target": dict(pt(1900, 6200), z=900), "distanceMm": 3400, "yawDeg": 0, "pitchDeg": -22, "fovDeg": 60}
DINING = {"mode": "orbit", "target": dict(pt(2900, 4400), z=500), "distanceMm": 3600, "yawDeg": 35, "pitchDeg": -32, "fovDeg": 55}
BEDROOM = {"mode": "firstPerson", "target": dict(pt(9000, 4350), z=1700), "yawDeg": 90, "pitchDeg": -22, "fovDeg": 75}
BATH = {"mode": "orbit", "target": dict(pt(8430, 1250), z=500), "distanceMm": 4200, "yawDeg": 180, "pitchDeg": -78, "fovDeg": 55}
TOP = {"mode": "top", "target": dict(pt(4630, 3380), z=0), "distanceMm": 7200, "yawDeg": 0}
MATERIALS_CAM = {"mode": "orbit", "target": dict(pt(2800, 2300), z=600), "distanceMm": 4600, "yawDeg": 250, "pitchDeg": -22,
                 "fovDeg": 60}
# wide aerial with see-through walls for the GIFs that need the whole flat
AERIAL_GIF = {"mode": "orbit", "target": dict(pt(4630, 3380), z=0), "distanceMm": 12000, "yawDeg": -10, "pitchDeg": -52,
              "fovDeg": 45}
KITCHEN_OPEN = {"mode": "orbit", "target": dict(pt(1900, 6250), z=950), "distanceMm": 3600, "yawDeg": -12, "pitchDeg": -16,
                "fovDeg": 60}
WARDROBE_OPEN = {"mode": "orbit", "target": dict(pt(8000, 6300), z=1100), "distanceMm": 3300, "yawDeg": 10, "pitchDeg": -12,
                 "fovDeg": 60}
DRESSER_OPEN = {"mode": "orbit", "target": dict(pt(8890, 3015), z=550), "distanceMm": 2500, "yawDeg": 265, "pitchDeg": -20,
                "fovDeg": 55}

# ---------------------------------------------------------------- GIFs on the refined project


def gif_day_to_night(c, work, groups):
    """Sun path with moving shadows, dusk, then the lamps switch on one group after the other and night falls."""
    cam = lambda t: dict(AERIAL_GIF, yawDeg=lerp(-14, 12, t))
    seq = []  # (state, kind): kind "move" = next state follows continuously, "cut" = dissolve to the next state

    def state(minutes, mood, exposure, lamps):
        return (round(minutes), mood, round(exposure, 2), lamps)

    for k in range(46):  # 07:30 to 18:30, daylight
        seq.append((state(lerp(450, 1110, k / 45), "daylight", 0, 0), "move"))
    seq[-1] = (seq[-1][0], "cut")
    for k in range(10):  # dusk 19:00 to 20:30, brighter exposure as the light fades; the lamps follow one by one
        m = lerp(1140, 1230, k / 9)
        exp = lerp(1.5, 2.4, k / 9)
        lamps = 0 if k < 3 else 1 if k < 5 else 2 if k < 7 else 3
        kind = "cut" if k in (2, 4, 6) else "move"
        seq.append((state(m, "evening", exp, lamps), kind))
    seq[-1] = (seq[-1][0], "cut")
    for k in range(12):  # night
        seq.append((state(lerp(1260, 1380, k / 11), "night", 2.6, 3), "move"))
    total = len(seq) + 3 * sum(1 for i, (_, kind) in enumerate(seq) if kind == "cut" and i + 1 < len(seq))
    specs, f = [], 0
    for i, (s, kind) in enumerate(seq):
        t = f / (total - 1)
        specs.append(((s, cam(t)), None, 0))
        f += 1
        if kind == "cut" and i + 1 < len(seq):
            for sp in dissolve((s, cam(f / (total - 1))), (seq[i + 1][0], cam(f / (total - 1))), 3):
                specs.append(sp)
                f += 1
    specs += [(specs[-1][0], None, 0)] * 6  # hold the last picture

    def apply(c, s):
        minutes, mood, exposure, lamps = s
        c.call("light.set", mood=mood, applyMoodTime=False, timeMinutes=minutes, exposure=exposure)
        for g, ids in enumerate(groups):
            lamps_on(c, ids, g < lamps)

    c.call("view.set", wallOpacity=0.3)
    render_specs(c, os.path.join(work, "day-to-night"), specs, apply)
    c.call("view.set", wallOpacity=1.0)
    for ids in groups:
        lamps_on(c, ids, False)
    c.call("light.set", mood="daylight", applyMoodTime=True, exposure=0)


def gif_lamps(c, work, groups):
    """The lamps of the flat switch on one group after the other at night: floor lamp, pendants, table lamps."""
    n = len(groups) + 1
    hold, fade = 7, 4
    total = n * hold + (n - 1) * fade
    cam = lambda f: dict(AERIAL_GIF, distanceMm=11000, yawDeg=lerp(-18, 14, ease(f / (total - 1))))
    specs, f = [], 0
    for g in range(n):
        for _ in range(hold):
            specs.append(((g, cam(f)), None, 0))
            f += 1
        if g + 1 < n:
            for k in range(fade):
                specs.append(((g, cam(f)), (g + 1, cam(f)), ease((k + 1) / (fade + 1))))
                f += 1

    def apply(c, lamps):
        for g, ids in enumerate(groups):
            lamps_on(c, ids, g < lamps)

    c.call("view.set", wallOpacity=0.3)
    c.call("light.set", mood="night", applyMoodTime=True, exposure=4.5)
    render_specs(c, os.path.join(work, "lamps"), specs, apply)
    c.call("view.set", wallOpacity=1.0)
    for ids in groups:
        lamps_on(c, ids, False)
    c.call("light.set", mood="daylight", applyMoodTime=True, exposure=0)


STEPS = 8  # intermediate poses between "closed" and "open"


def define_steps(c, definition_id):
    """Defines the states t1..t7 between "closed" and "open" of a design by interpolating its "open" poses.

    furniture.activate_state renders the end state without animating, so the GIF defines the in-between poses itself."""
    d = c.call("scene.get_object", id=definition_id)
    comps = {x["id"]: x for x in d["components"]}
    open_state = next(s for s in d["states"] if s["name"] == "open")
    for k in range(1, STEPS):
        f = k / STEPS
        poses = {}
        for p in open_state["poses"]:
            base = comps[p["componentId"]]
            pose = {}
            for key in ("position", "rotation"):
                if key in p:
                    pose[key] = {a: round(lerp(base[key][a], p[key][a], f), 1) for a in "xyz"}
            poses[p["componentId"]] = pose
        c.call("furniture.define_state", definitionId=definition_id, name="t%d" % k, poses=poses)


def step_state(k):
    return "closed" if k == 0 else "open" if k == STEPS else "t%d" % k


def gif_doors_states(c, work):
    """Fridge and oven, wardrobe, then the dresser drawers open and close (furniture states with in-between poses)."""
    scenes = [  # (camera, camera end yaw, pieces: name -> start delay in frames)
        (KITCHEN_OPEN, -2, {"Refrigerator": 0, "Cooker": 5}),
        (WARDROBE_OPEN, -6, {"Wardrobe": 0}),
        (DRESSER_OPEN, 280, {"Dresser": 0}),
    ]
    pieces = {n: piece(c, n) for _, _, ps in scenes for n in ps}
    for n in pieces:
        define_steps(c, pieces[n]["definitionId"])
    hold_closed, move, hold_open = 5, 14, 8
    frames_per_scene = hold_closed + move + hold_open + move + 3
    specs, last = [], None
    for cam0, yaw_end, ps in scenes:
        cams = cam_sweep(cam0, frames_per_scene, yawDeg=yaw_end)
        delay_max = max(ps.values())
        scene_specs = []
        for f in range(frames_per_scene):
            st = {}
            for n, delay in ps.items():
                g = f - hold_closed - delay
                if g < 0:
                    k = 0
                elif g < move:
                    k = round(STEPS * ease(g / (move - 1)))
                elif g < move + hold_open:
                    k = STEPS
                else:
                    h = g - move - hold_open - 0
                    k = round(STEPS * (1 - ease(min(h / (move - 1), 1))))
                st[n] = k
            scene_specs.append(((tuple(sorted(st.items())), cams[f]), None, 0))
        if last is not None:
            specs += dissolve(last, scene_specs[0][0], 3)
        specs += scene_specs
        last = scene_specs[-1][0]

    def apply(c, s):
        for n, k in s:
            c.call("furniture.activate_state", ids=[pieces[n]["id"]], state=step_state(k))

    render_specs(c, os.path.join(work, "doors-states"), specs, apply)
    for n in pieces:
        c.call("furniture.activate_state", ids=[pieces[n]["id"]], state="closed")


FLOORS = {"oak": ("wood-oak", "#C9A06C"), "tiles": ("tiles-white", "#D8DCDF"), "stone": ("tiles-anthracite", "#585C63")}
WALLS_COLOUR = {"white": "#F4F1EA", "sage": "#B3C4AB", "clay": "#E0BBA3"}
FABRICS = {"charcoal": "Charcoal", "rust": "Rust", "sage": "Sage"}


def gif_materials(c, work):
    """The living room changes its floor (oak, tiles, stone), wall colour and sofa fabric."""
    sofa = piece(c, "Sofa")
    grey = demo.palette_id("Grey fabric")
    d = c.call("scene.get_object", id=sofa["definitionId"])
    parts = [x["id"] for x in d["components"] if x["materialId"] == grey]
    if not parts:
        sys.exit("sofa has no 'Grey fabric' parts")
    c.call("furniture.define_option_group", definitionId=sofa["definitionId"], name="Fabric", defaultChoice="Charcoal",
           choices=[{"name": "Charcoal", "effects": {p: {"material": "Grey fabric"} for p in parts}},
                    {"name": "Rust", "effects": {p: {"material": "Velvet rust"} for p in parts}},
                    {"name": "Sage", "effects": {p: {"material": "Velvet sage"} for p in parts}}])
    seq = [("oak", "white", "charcoal"), ("tiles", "white", "charcoal"), ("stone", "white", "charcoal"),
           ("oak", "white", "charcoal"), ("oak", "sage", "charcoal"), ("oak", "clay", "charcoal"),
           ("oak", "white", "charcoal"), ("oak", "white", "rust"), ("oak", "white", "sage"), ("oak", "white", "charcoal")]
    hold, fade = 6, 4
    total = len(seq) * hold + (len(seq) - 1) * fade
    cams = cam_sweep(dict(SOFA, distanceMm=3300, yawDeg=272, pitchDeg=-22), total, yawDeg=290)
    specs, f = [], 0
    for i, s in enumerate(seq):
        for _ in range(hold):
            specs.append(((s, cams[f]), None, 0))
            f += 1
        if i + 1 < len(seq):
            for k in range(fade):
                specs.append(((s, cams[f]), (seq[i + 1], cams[f]), ease((k + 1) / (fade + 1))))
                f += 1
    prev = {}

    def apply(c, s):
        floor, wall, fabric = s
        if prev.get("floor") != floor:
            preset, colour = FLOORS[floor]
            c.call("material.apply_preset", id=uid("mat Oak parquet"), preset=preset)
            c.call("material.update", id=uid("mat Oak parquet"), color=colour)
        if prev.get("wall") != wall:
            c.call("material.update", id=uid("mat Wall white"), color=WALLS_COLOUR[wall])
        if prev.get("fabric") != fabric:
            c.call("furniture.set_options", ids=[sofa["id"]], options={"Fabric": FABRICS[fabric]})
        prev.update(floor=floor, wall=wall, fabric=fabric)

    render_specs(c, os.path.join(work, "materials"), specs, apply)
    apply(c, ("oak", "white", "charcoal"))


def gif_camera_modes(c, work):
    """The four camera modes in turn: orbit around the sofa, top view, aerial with see-through walls, first-person walk."""
    orbit = cam_sweep(dict(SOFA, yawDeg=272, distanceMm=3200, pitchDeg=-20), 20, yawDeg=296)
    top = cam_sweep(dict(TOP, distanceMm=10000), 16, distanceMm=7400, yawDeg=-12)
    aerial = cam_sweep(dict(AERIAL_GIF, yawDeg=10), 20, yawDeg=90)
    walk = [{"mode": "firstPerson", "target": dict(pt(round(x), round(y)), z=1600), "yawDeg": yaw, "pitchDeg": -3, "fovDeg": 62}
            for x, y, yaw in walk_path(22)]
    specs, last = [], None
    for cams, wall in ((orbit, 1.0), (top, 1.0), (aerial, 0.3), (walk, 1.0)):
        seg = [((wall, cam), None, 0) for cam in cams]
        if last is not None:
            specs += dissolve(last, seg[0][0], 3)
        specs += seg
        last = seg[-1][0]

    def apply(c, wall):
        c.call("view.set", wallOpacity=wall)

    render_specs(c, os.path.join(work, "camera-modes"), specs, apply)
    c.call("view.set", wallOpacity=1.0)


# ---------------------------------------------------------------- builds that replace the project


def furniture_room(x, y):
    """Room of a FURNITURE row by its coordinates (the demo flat has five zones)."""
    if x < 5800:
        return "living" if y < 3600 else "kitchen"
    if y < 2500:
        return "hall" if x < 7600 else "bath"
    return "bedroom"


def gif_ai_build(c, work):
    """The flat grows step by step, as an agent builds it from a prompt: walls, openings, rooms and floors, furniture room by
    room, finally the styling. One aerial picture per agent batch, dissolved into the next; the camera drifts slowly."""
    c.call("project.new", discard=True)
    c.call("project.update_settings", name="Demo Apartment")
    c.batch([("material.create", {"id": uid("mat " + n), "name": n, "color": col, "roughness": r})
             for n, col, r in demo.MATERIALS])
    c.call("view.set", wallOpacity=0.3)
    c.call("light.set", mood="daylight", applyMoodTime=True, exposure=0)
    walls = list(demo.WALLS.items())

    def wall_steps(rows):
        return lambda: c.batch([("geometry.create_wall", {"id": uid("wall " + n), "start": pt(*a), "end": pt(*b),
                                                          "thicknessMm": t, "heightMm": 2600}) for n, (a, b, t) in rows])

    def wall_finish():
        inner = [uid("wall " + n) for n, w in demo.WALLS.items() if w[2] == demo.INNER]
        outer = [uid("wall " + n) for n, w in demo.WALLS.items() if w[2] == demo.OUTER]
        c.batch([("scene.set_material", {"ids": inner, "slot": "wallBoth", "material": "Wall white"}),
                 ("scene.set_material", {"ids": outer, "slot": "wallRight", "material": "Outer plaster"}),
                 ("scene.set_material", {"ids": outer, "slot": "wallLeft", "material": "Wall white"})])

    def openings(kind):
        def run():
            steps = []
            for wall, typ, off, w, h, sill, name, inward in demo.OPENINGS:
                if typ != kind:
                    continue
                args = {"id": uid("opening " + name), "wallId": uid("wall " + wall), "type": typ, "offsetMm": off,
                        "widthMm": w, "heightMm": h, "name": name}
                if sill is not None:
                    args["sillMm"] = sill
                steps.append(("geometry.add_opening", args))
                if inward is not None:
                    steps.append(("geometry.update_opening", {"id": args["id"], "inward": inward}))
            c.batch(steps)
        return run

    def rooms():
        for name, p, floor in demo.ROOMS:
            c.call("geometry.create_room_from_walls", id=uid("room " + name), name=name, point=pt(*p))
        c.batch([("geometry.update_room", {"id": uid("room " + n), "floorMaterial": f}) for n, _, f in demo.ROOMS])
        c.batch([("geometry.update_wall", {"id": uid("wall V2"), "rightMaterial": "Light tiles"}),
                 ("geometry.update_wall", {"id": uid("wall H1b"), "rightMaterial": "Light tiles"}),
                 ("geometry.update_wall", {"id": uid("wall V1b"), "rightMaterial": "Accent sage"})])

    def furniture(zones):
        def run():
            steps = []
            for key, x, y, rot, z, name in demo.FURNITURE:
                if furniture_room(x, y) not in zones:
                    continue
                pos = pt(x, y)
                if z:
                    pos["z"] = z
                steps.append(("catalog.insert_builtin", {"key": key, "position": pos, "rotationDeg": rot, "name": name}))
            c.batch(steps)
        return run

    def styling():
        demo.showcase(c)
        refine(c)

    def lights():
        lamps_on(c, [i for g in lamp_groups(c) for i in g], True)
        c.call("light.set", mood="evening", applyMoodTime=True, exposure=2.0)

    stages = [
        lambda: None,
        wall_steps(walls[:4]), wall_steps(walls[4:8]), wall_steps(walls[8:]), wall_finish,
        openings("door"), openings("window"),
        rooms,
        furniture({"living"}), furniture({"kitchen"}), furniture({"hall", "bath"}), furniture({"bedroom"}),
        styling,
    ]
    hold, fade = 5, 4
    total = len(stages) * hold + (len(stages) - 1) * fade
    cams = cam_sweep(dict(AERIAL_GIF, distanceMm=12500, yawDeg=35, pitchDeg=-55), total, yawDeg=-8)
    frames = os.path.join(work, "ai-build")
    shutil.rmtree(frames, ignore_errors=True)
    os.makedirs(frames)
    size, f, pending = GIF_SIZE, 0, []

    def flush():  # renders the B side of the dissolves of the previous stage, now that the next stage exists
        for path, cam, alpha in pending:
            render(c, path + ".b.png", cam, size)
            blend(path + ".a.png", path + ".b.png", alpha, path)
            os.remove(path + ".a.png")
            os.remove(path + ".b.png")
        pending.clear()

    for i, stage in enumerate(stages):
        stage()
        flush()
        for _ in range(hold):
            render(c, os.path.join(frames, "f%03d.png" % f), cams[f], size)
            f += 1
        if i + 1 < len(stages):
            for k in range(fade):
                path = os.path.join(frames, "f%03d.png" % f)
                render(c, path + ".a.png", cams[f], size)
                pending.append((path, cams[f], ease((k + 1) / (fade + 1))))
                f += 1
    flush()
    # the last stage is the finished flat: hold it a little longer
    last = os.path.join(frames, "f%03d.png" % (f - 1))
    for k in range(10):
        shutil.copy(last, os.path.join(frames, "f%03d.png" % (f + k)))
    c.call("view.set", wallOpacity=1.0)


def prompt_kit(c, out):
    """A sideboard and a desk as an agent builds them from a one-sentence prompt (designs in scripts/media-prompt-kit.json)."""
    kit = json.load(open(os.path.join(HERE, "media-prompt-kit.json")))
    c.call("project.new", discard=True)
    c.call("project.update_settings", name="Prompt kit")
    for m in kit["materials"]:
        c.call("material.create", **m)
    c.batch([("material.create", {"id": uid("mat floor"), "name": "Floor oak", "color": "#C9A06C", "roughness": 0.5}),
             ("material.create", {"id": uid("mat wall"), "name": "Wall", "color": "#EDE8DD", "roughness": 0.9})])
    c.batch([("geometry.create_wall", {"id": uid("kit wall " + n), "start": pt(*a), "end": pt(*b), "thicknessMm": 150,
                                       "heightMm": 2600})
             for n, (a, b) in {"s": ((0, 0), (5200, 0)), "e": ((5200, 0), (5200, 3000)), "n": ((5200, 3000), (0, 3000)),
                               "w": ((0, 3000), (0, 0))}.items()])
    c.call("scene.set_material", ids=[uid("kit wall " + n) for n in "sewn"], slot="wallBoth", material="Wall")
    c.call("geometry.create_room_from_walls", id=uid("kit room"), name="Study", point=pt(2600, 1500))
    c.call("geometry.update_room", id=uid("kit room"), floorMaterial="Floor oak")
    sideboard = c.call("furniture.create_definition", **kit["definitions"][0])
    desk = c.call("furniture.create_definition", **kit["definitions"][1])
    c.call("furniture.create_instance", definitionId=sideboard["id"], position=pt(1500, 2650), rotationDeg=180, name="Sideboard")
    c.call("furniture.create_instance", definitionId=desk["id"], position=pt(3900, 2600), rotationDeg=180, name="Desk")
    c.call("view.set", wallOpacity=1.0)
    render(c, out, {"mode": "firstPerson", "target": dict(pt(2700, 350), z=1350), "yawDeg": 0, "pitchDeg": -12, "fovDeg": 70})


def plan_dimensions(c, out):
    """The empty flat as a drawing: walls, openings, rooms and the dimension chains (furniture hidden)."""
    ids = [i["id"] for i in c.call("scene.list_objects", kind="furniture", limit=200)["items"]]
    c.call("scene.set_visible", ids=ids, visible=False)
    plan_png(c, out)
    c.call("scene.set_visible", ids=ids, visible=True)


def plan_png(c, out):
    """render.plan_image, cropped to the drawing (the A3 sheet leaves wide margins)."""
    tmp = out + ".full.png"
    c.call("render.plan_image", path=tmp, overwrite=True, paper="A3", scale="fit", dpi=150, orientation="landscape")
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", tmp, "-vf", PLAN_CROP, "-frames:v", "1", out], check=True)
    os.remove(tmp)


# crop of the A3 landscape sheet at 150 dpi (2480x1754): the drawing and its dimension chains with an even margin
PLAN_CROP = "crop=1400:1040:540:340"


GALLERY = {  # name -> (camera, light.set arguments or None for daylight, lamps on)
    "gallery-living": (SOFA, None, False),
    "gallery-kitchen": (KITCHEN, None, False),
    "gallery-bedroom": (BEDROOM, None, False),
    "gallery-bath": (BATH, None, False),
    "gallery-dining": (DINING, None, False),
    "gallery-evening-living": (LIVING, EVENING_LIGHT, True),
    "gallery-night-bedroom": (BEDROOM, NIGHT_LIGHT, True),
}
# rendered on the refined project, in this order (they never change the project permanently)
STILLS = ("hero-aerial", "interior", "walls-transparent", "doors-windows", "evening", "night") + tuple(GALLERY) + (
    "plan-dimensions", "plan-furnished")
GIFS = ("orbit", "walkthrough", "day-to-night", "lamps", "doors-states", "materials", "camera-modes")
# these replace the open project, so they come last: the prompt-kit pictures, then the AI build GIF
REBUILDS = ("prompt-kit-furniture", "ai-build")
NAMES = STILLS + GIFS + REBUILDS
# `ruler-3d` is not here on purpose: the 3D ruler works by clicks in the live window only (no agent tool, no offscreen mode).


def main():
    ap = argparse.ArgumentParser(description="Render the README pictures and GIFs of the Demo Apartment.")
    ap.add_argument("mcp", help="path to the roomsmith-mcp program")
    ap.add_argument("images", help="folder that receives the PNG and GIF files (docs/images)")
    ap.add_argument("--work", help="folder for the project and the GIF frames (default: a temporary folder, removed at the end)")
    ap.add_argument("--only", help="comma-separated names of the pictures/GIFs to render (default: all)")
    ap.add_argument("--keep", action="store_true", help="keep the work folder")
    args = ap.parse_args()
    images = os.path.abspath(args.images)
    only = set(args.only.split(",")) if args.only else None
    if only is not None and only - set(NAMES):
        ap.error("unknown --only name(s): %s (known: %s)" % (", ".join(sorted(only - set(NAMES))), ", ".join(NAMES)))
    work = os.path.abspath(args.work) if args.work else tempfile.mkdtemp(prefix="roomsmith-media-")

    def want(name):
        return only is None or name in only

    os.makedirs(images, exist_ok=True)
    os.makedirs(work, exist_ok=True)
    c = None
    try:
        c = demo.Client(args.mcp)
        demo.build(c, os.path.join(work, "project"), None)
        lamp_ids = refine(c)
        groups = lamp_groups(c)
        lamps_on(c, lamp_ids, False)
        c.call("light.set", mood="daylight", applyMoodTime=True, exposure=0)
        # the refined project in daylight with lamps off (for window pictures:
        # ROOMSMITH_OPEN=<work>/refined/Demo Apartment.roomsmith); it is not an example file
        os.makedirs(os.path.join(work, "refined"), exist_ok=True)
        c.call("project.save_as", path=os.path.join(work, "refined", "Demo Apartment.roomsmith"), overwrite=True)
        out = lambda n: os.path.join(images, n)

        # daylight pictures, lamps off
        if want("hero-aerial"):
            render(c, out("hero-aerial.png"), AERIAL)
        if want("interior"):
            render(c, out("interior.png"), LIVING)
        if want("walls-transparent"):
            c.call("view.set", wallOpacity=0.25)
            render(c, out("walls-transparent.png"), AERIAL)
            c.call("view.set", wallOpacity=1.0)
        if want("doors-windows"):
            render(c, out("doors-windows.png"), DOORS_WINDOWS)
        for name, (cam, light, lamps) in GALLERY.items():
            if not want(name):
                continue
            if lamps:
                lamps_on(c, lamp_ids, True)
                c.call("light.set", **light)
            render(c, out(name + ".png"), cam)
            if lamps:
                lamps_on(c, lamp_ids, False)
                c.call("light.set", mood="daylight", applyMoodTime=True, exposure=0)
        if want("plan-furnished"):  # the furniture seen from straight above (3D top view)
            render(c, out("plan-furnished.png"), TOP)
        if want("plan-dimensions"):
            plan_dimensions(c, out("plan-dimensions.png"))

        # evening and night, lamps on
        if want("evening") or want("night"):
            lamps_on(c, lamp_ids, True)
            if want("evening"):
                c.call("light.set", **EVENING_LIGHT)
                render(c, out("evening.png"), EVENING)
            if want("night"):
                c.call("light.set", **NIGHT_LIGHT)
                render(c, out("night.png"), NIGHT)
            lamps_on(c, lamp_ids, False)
            c.call("light.set", mood="daylight", applyMoodTime=True, exposure=0)

        # GIFs
        if want("orbit"):
            frames = os.path.join(work, "orbit")
            shutil.rmtree(frames, ignore_errors=True)
            os.makedirs(frames)
            n = 60
            for f in range(n):
                cam = dict(AERIAL, yawDeg=AERIAL["yawDeg"] + 360 * f / n)
                render(c, os.path.join(frames, "f%03d.png" % f), cam, GIF_SIZE)
            make_gif(frames, out("orbit.gif"), 12)
        if want("walkthrough"):
            frames = os.path.join(work, "walkthrough")
            shutil.rmtree(frames, ignore_errors=True)
            os.makedirs(frames)
            for f, (x, y, yaw) in enumerate(walk_path(70)):
                cam = {"mode": "firstPerson", "target": dict(pt(round(x), round(y)), z=1600), "yawDeg": yaw, "pitchDeg": -3,
                       "fovDeg": 62}
                render(c, os.path.join(frames, "f%03d.png" % f), cam, GIF_SIZE)
            make_gif(frames, out("walkthrough.gif"), 12)
        for name, fn, fps in (("day-to-night", lambda: gif_day_to_night(c, work, groups), 12),
                              ("lamps", lambda: gif_lamps(c, work, groups), 12),
                              ("doors-states", lambda: gif_doors_states(c, work), 12),
                              ("materials", lambda: gif_materials(c, work), 12),
                              ("camera-modes", lambda: gif_camera_modes(c, work), 12)):
            if want(name):
                fn()
                make_gif(os.path.join(work, name), out(name + ".gif"), fps)

        # these replace the open project
        if want("prompt-kit-furniture"):
            prompt_kit(c, out("prompt-kit-furniture.png"))
        if want("ai-build"):
            gif_ai_build(c, work)
            make_gif(os.path.join(work, "ai-build"), out("ai-build.gif"), 12)
    finally:
        if c is not None:
            c.close()
        if not args.keep and not args.work:
            shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
