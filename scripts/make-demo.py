#!/usr/bin/env python3
"""Build the "Demo Apartment" example project through the Roomsmith agent API (MCP).

Usage: make-demo.py <path-to-roomsmith-mcp> <output-folder> [--images <folder>]

The app must already be running; its agent socket is taken from ROOMSMITH_SOCKET
(and ROOMSMITH_SUPPORT_DIR for the token), exactly like roomsmith-mcp itself reads them.
The script replaces the open project (project.new with discard), builds the apartment with
batched tool calls and finally saves "<output-folder>/Demo Apartment.roomsmith".
With --images it also writes plan.png and aerial.png of the result into that folder.

Layout (millimetres, X east, Y north; wall axes 0..9260 x 0..6760, outer size 9500 x 7000):

    y 6760 +--------------------------------+-----------------------------+
           |  Living room + open kitchen    |  Bedroom                    |
           |  (kitchen along the north wall)|                             |
    y 2500 |                                +-----------+-----------------+
           |                                |  Hallway  |  Bathroom       |
    y 0    +--------------------------------+-----------+-----------------+
         x 0                              5800        7600              9260
"""
import argparse
import hashlib
import json
import math
import os
import subprocess
import sys
import time
import uuid

NS = uuid.UUID("5d0c1e3a-7a43-4d8e-9b50-2f1c6a9e0b11")


def uid(name):
    """Stable id derived from `name` for the ids this script chooses itself; ids the app assigns (instances, dimensions,
    cameras) still differ between runs."""
    return str(uuid.uuid5(NS, name))


class Client:
    """Minimal MCP (JSON-RPC over stdio) client for roomsmith-mcp."""

    def __init__(self, mcp_path):
        sock = os.environ.get("ROOMSMITH_SOCKET")
        if not sock:
            sys.exit("ROOMSMITH_SOCKET is not set")
        for _ in range(120):  # the socket appears a few seconds after the app started
            if os.path.exists(sock):
                break
            time.sleep(0.5)
        else:
            sys.exit("agent socket did not appear within 60 s: " + sock)
        self.proc = subprocess.Popen([mcp_path], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     text=True)
        self.n = 0
        self._rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                 "clientInfo": {"name": "make-demo", "version": "1"}})
        self._send({"jsonrpc": "2.0", "method": "notifications/initialized"})

    def _send(self, msg):
        self.proc.stdin.write(json.dumps(msg) + "\n")
        self.proc.stdin.flush()

    def _rpc(self, method, params):
        self.n += 1
        self._send({"jsonrpc": "2.0", "id": self.n, "method": method, "params": params})
        line = self.proc.stdout.readline()
        if not line:
            sys.exit("roomsmith-mcp closed the connection")
        return json.loads(line)

    def call(self, tool, **args):
        reply = self._rpc("tools/call", {"name": tool, "arguments": args})
        res = reply.get("result", reply)
        data = res.get("structuredContent")
        if data is None:
            text = "".join(c.get("text", "") for c in res.get("content", []))
            try:
                data = json.loads(text)
            except ValueError:
                data = {"text": text}
        if res.get("isError") or "error" in reply:
            sys.exit("%s failed: %s" % (tool, json.dumps(data if res.get("isError") else reply)[:800]))
        return data

    def batch(self, steps):
        return self.call("app.batch", steps=[{"tool": t, "arguments": a} for t, a in steps])

    def close(self):
        self.proc.stdin.close()
        self.proc.wait()


def pt(x, y):
    return {"x": x, "y": y}


def palette_id(name):
    """Id of a built-in palette material (every new project starts with the palette; same rule as StableID.uuid)."""
    b = bytearray(hashlib.sha256(("material/" + name).encode()).digest()[:16])
    b[6] = (b[6] & 0x0F) | 0x50
    b[8] = (b[8] & 0x3F) | 0x80
    return str(uuid.UUID(bytes=bytes(b)))


# ---------------------------------------------------------------- walls

OUTER, INNER = 240, 115
WALLS = {  # name: (start, end, thickness); every T junction has a shared end point
    "S1": ((0, 0), (5800, 0), OUTER),
    "S2": ((5800, 0), (7600, 0), OUTER),
    "S3": ((7600, 0), (9260, 0), OUTER),
    "E1": ((9260, 0), (9260, 2500), OUTER),
    "E2": ((9260, 2500), (9260, 6760), OUTER),
    "N1": ((9260, 6760), (5800, 6760), OUTER),
    "N2": ((5800, 6760), (0, 6760), OUTER),
    "W": ((0, 6760), (0, 0), OUTER),
    "V1a": ((5800, 0), (5800, 2500), INNER),
    "V1b": ((5800, 2500), (5800, 6760), INNER),
    "V2": ((7600, 0), (7600, 2500), INNER),
    "H1a": ((5800, 2500), (7600, 2500), INNER),
    "H1b": ((7600, 2500), (9260, 2500), INNER),
}

# (wall, type, centre offset along the wall from its start, width, height, sill, name, opens to the left?)
OPENINGS = [
    ("S2", "door", 1200, 1000, 2100, None, "Entrance door", True),
    ("V1a", "door", 800, 900, 2100, None, "Door hallway - living room", True),
    ("V2", "door", 1700, 800, 2100, None, "Door hallway - bathroom", True),
    ("H1a", "door", 1100, 900, 2100, None, "Door hallway - bedroom", True),
    ("S1", "window", 1500, 1600, 1400, 700, "Living room window south 1", None),
    ("S1", "window", 4000, 1600, 1400, 700, "Living room window south 2", None),
    ("W", "window", 2310, 1600, 1400, 700, "Dining window west", None),
    ("N2", "window", 3880, 1200, 1000, 1200, "Kitchen window", None),
    ("N2", "window", 1000, 1600, 1400, 700, "Living room window north", None),
    ("N1", "window", 2760, 1000, 1400, 800, "Bedroom window north", None),
    ("E2", "window", 1850, 1400, 1400, 800, "Bedroom window east", None),
    ("S3", "window", 1090, 600, 600, 1300, "Bathroom window", None),
]

# ---------------------------------------------------------------- showcase detail
# Everything below is built through the agent API, like a user's own designs: the built-in catalog stays plain.

# palette material -> material.update arguments (procedural surfaces; furniture UVs are millimetres)
WOOD = {"pattern": "wood", "finish": "satin", "textureTileMm": 800, "patternSizeMm": 160, "groutMm": 0}
WEAVE = {"pattern": "fabric", "textureTileMm": 240, "patternSizeMm": 4, "groutMm": 0, "specular": 0.3}
SURFACES = {
    "Oak": dict(WOOD, color2="#A9814F"),
    "Walnut": dict(WOOD, color2="#4E3322"),
    "Birch": dict(WOOD, color2="#CBB083"),
    "White lacquer": {"finish": "satin", "clearcoat": 0.4},
    "Grey fabric": dict(WEAVE, color2="#7D8085"),
    "Beige fabric": dict(WEAVE, color2="#C6B89E"),
    "Brown leather": {"pattern": "leather", "textureTileMm": 300, "patternSizeMm": 12, "groutMm": 0, "clearcoat": 0.1},
    "Black metal": {"finish": "satin"},
    "Chrome": {"finish": "polished"},
    "Stainless steel": {"finish": "brushed"},
    "Glass": {"finish": "polished", "specular": 0.8},
    "White ceramic": {"finish": "polished", "clearcoat": 0.6, "specular": 0.6},
    "Screen black": {"finish": "polished", "clearcoat": 0.8},
    "Sand wool": dict(WEAVE, color2="#B6A485", patternSizeMm=6),
    "Lampshade": dict(WEAVE, color2="#E6DAC0", patternSizeMm=3),
    "White linen": dict(WEAVE, color2="#E1DDD3", patternSizeMm=3),
    "Dark stone": {"finish": "polished"},
}

DECOR_MATERIALS = [  # name, colour, roughness, extra material.create arguments
    ("Terracotta", "#B4673F", 0.9, {}),
    ("Leaf dark", "#3E6331", 0.8, {"finish": "satin"}),
    ("Curtain linen", "#E8E1D2", 0.95, dict(WEAVE, color2="#DAD1BF", patternSizeMm=3)),
    ("Velvet rust", "#A4583A", 0.9, dict(WEAVE, color2="#8E4A30", patternSizeMm=2)),
    ("Velvet sage", "#8FA287", 0.9, dict(WEAVE, color2="#7C8F74", patternSizeMm=2)),
    ("Book red", "#8C3B33", 0.75, {"finish": "satin"}),
    ("Book blue", "#34506C", 0.75, {"finish": "satin"}),
    ("Book cream", "#E6DCC6", 0.8, {}),
    ("Book green", "#4E6A4F", 0.75, {"finish": "satin"}),
    ("Book ochre", "#C39A46", 0.75, {"finish": "satin"}),
    ("Orange", "#DB8432", 0.5, {"finish": "satin"}),
    ("Apple green", "#93B04C", 0.45, {"finish": "satin"}),
]
BOOKS = ["Book red", "Book blue", "Book cream", "Book green", "Book ochre"]


def part(name, shape, x, y, z, material, rot=None):
    """One component from per-axis ranges (min, max) in mm, like the catalog's part builder."""
    c = {"name": name, "shape": shape, "material": material,
         "position": {"x": round((x[0] + x[1]) / 2), "y": round((y[0] + y[1]) / 2), "z": round((z[0] + z[1]) / 2)},
         "size": {"width": round(x[1] - x[0]), "depth": round(y[1] - y[0]), "height": round(z[1] - z[0])}}
    if rot:
        c["rotation"] = {"x": rot[0], "y": rot[1], "z": rot[2]}
    return c


def plant_parts():
    """Terracotta pot (an upside-down taper widens upwards), stems and a crown of tilted leaf blades."""
    ps = [part("Pot", "taper", (-160, 160), (-160, 160), (0, 330), "Terracotta", (180, 0, 0)),
          part("Pot rim", "cylinder", (-168, 168), (-168, 168), (310, 336), "Terracotta"),
          part("Soil", "cylinder", (-150, 150), (-150, 150), (300, 318), "Soil"),
          part("Foliage core", "sphere", (-150, 150), (-150, 150), (760, 1180), "Leaf dark")]
    for i, (dx, tilt) in enumerate([(-30, 6), (25, -5), (0, 0)]):
        ps.append(part("Stem %d" % (i + 1), "cylinder", (dx - 7, dx + 7), (-7, 7), (318, 950 - 60 * i), "Walnut",
                       (tilt, 0, 0)))
    for i in range(18):
        phi = math.radians(i * 137.5)
        tilt = 26 + (i % 5) * 8
        d = 60 + (i % 3) * 25
        zc = 640 + i * 34
        cx, cy = d * math.sin(phi), -d * math.cos(phi)
        mat = "Leaf green" if i % 3 else "Leaf dark"
        ps.append(part("Leaf %d" % (i + 1), "sphere", (cx - 60, cx + 60), (cy - 6, cy + 6), (zc - 175, zc + 175), mat,
                       (tilt, 0, (i * 137.5) % 360)))
    return ps


def bookcase_parts():
    """Walnut bookcase with rows of books, a lying stack, a vase and a bowl (deterministic)."""
    hw, hd, t = 400, 160, 20
    ps = [part("Side left", "rounded", (-hw, -hw + t), (-hd, hd), (0, 1900), "Walnut"),
          part("Side right", "rounded", (hw - t, hw), (-hd, hd), (0, 1900), "Walnut"),
          part("Top", "rounded", (-hw + t, hw - t), (-hd, hd), (1880, 1900), "Walnut"),
          part("Back", "box", (-hw + t, hw - t), (hd - 6, hd), (40, 1880), "Walnut"),
          part("Plinth", "box", (-hw + t, hw - t), (-hd + 30, hd - 6), (0, 40), "Walnut")]
    boards = [40, 420, 800, 1180, 1540]
    for i, z in enumerate(boards):
        ps.append(part("Board %d" % (i + 1), "rounded", (-hw + t, hw - t), (-hd, hd - 6), (z, z + t), "Walnut"))
    tops = boards[1:] + [1880]
    seed = 7
    def rnd(lo, hi):
        nonlocal seed
        seed = (seed * 1103515245 + 12345) % 2147483648
        return lo + seed % (hi - lo + 1)
    n = 0
    for row, (z0, z1) in enumerate(zip([b + t for b in boards], tops)):
        x = -hw + t + 6
        stop = hw - t - (240 if row in (1, 3) else 6)   # rows 2 and 4 leave room for decor
        while True:
            w, dep, h = rnd(24, 46), rnd(160, 220), min(rnd(200, 300), z1 - z0 - 25)
            if x + w > stop:
                break
            n += 1
            ps.append(part("Book %d" % n, "rounded", (x, x + w), (-hd + 12, -hd + 12 + dep), (z0, z0 + h),
                           BOOKS[(n * 3 + row) % len(BOOKS)]))
            x += w + 1
        if row == 1:
            ps.append(part("Vase", "taper", (stop + 70, stop + 170), (-60, 40), (z0, z0 + 220), "Terracotta"))
        if row == 3:
            for k in range(3):
                ps.append(part("Stack %d" % (k + 1), "rounded", (stop + 20 - 6 * k, stop + 220 - 6 * k), (-130, 30 - 8 * k),
                               (z0 + 32 * k, z0 + 32 * (k + 1)), BOOKS[(k + 2) % len(BOOKS)]))
            ps.append(part("Bowl", "sphere", (stop + 60, stop + 180), (-110, 10), (z0 + 96, z0 + 156), "White ceramic"))
    return ps


def curtain_panel_parts():
    """One curtain panel: soft vertical pleats of alternating depth."""
    return [part("Pleat %d" % (k + 1), "cylinder", (-215 + 61 * k, -215 + 61 * k + 72), (-70, 70) if k % 2 else (-50, 50),
                 (0, 2400), "Curtain linen") for k in range(7)]


def curtain_rod_parts():
    return [part("Rod", "rounded", (-950, 950), (-40, -18), (20, 42), "Black metal"),
            part("Finial left", "sphere", (-1000, -950), (-54, -4), (6, 56), "Black metal"),
            part("Finial right", "sphere", (950, 1000), (-54, -4), (6, 56), "Black metal"),
            part("Bracket left", "rounded", (-807, -793), (-30, 40), (24, 38), "Black metal"),
            part("Bracket right", "rounded", (793, 807), (-30, 40), (24, 38), "Black metal")]


def pillow_parts():
    return [part("Pillow left", "cushion", (-820, -380), (-75, 75), (20, 460), "Velvet rust", (-12, 0, 6)),
            part("Pillow right", "cushion", (380, 820), (-75, 75), (20, 460), "Velvet sage", (-12, 0, -5))]


def coffee_decor_parts():
    return [part("Book 1", "rounded", (-280, 20), (-110, 110), (0, 32), "Book cream", (0, 0, 6)),
            part("Book 2", "rounded", (-260, 0), (-95, 95), (32, 60), "Book blue", (0, 0, -4)),
            part("Bowl", "sphere", (80, 280), (-100, 100), (-40, 70), "Terracotta"),
            part("Vase", "taper", (-200, -120), (-40, 40), (60, 260), "White ceramic")]


def fruit_bowl_parts():
    ps = [part("Bowl", "sphere", (-170, 170), (-170, 170), (-60, 80), "White ceramic")]
    for k, (x, y, m) in enumerate([(-60, -30, "Orange"), (55, -40, "Apple green"), (0, 55, "Orange"), (10, -5, "Apple green")]):
        z = 40 if k < 3 else 100
        ps.append(part("Fruit %d" % (k + 1), "sphere", (x - 40, x + 40), (y - 40, y + 40), (z, z + 80), m))
    return ps


def kitchen_decor_parts():
    return [part("Board", "rounded", (-240, 80), (-20, 0), (0, 360), "Oak", (-8, 0, 0)),
            part("Jar 1", "cylinder", (100, 200), (-80, 20), (0, 220), "Glass"),
            part("Lid 1", "cylinder", (104, 196), (-76, 16), (220, 245), "Oak"),
            part("Jar 2", "cylinder", (215, 295), (-70, 10), (0, 170), "Glass"),
            part("Lid 2", "cylinder", (219, 291), (-66, 6), (170, 192), "Oak"),
            part("Jar 3", "cylinder", (-60, 40), (-150, -50), (0, 140), "White ceramic")]


def throw_parts():
    """A thin throw folded over the foot of the bed, narrower than the mattress so the duvet shows at its sides: a thin
    sheet on the duvet (top at z 290 here), a soft roll over the foot edge (a cylinder turned to lie along the bed's
    width) and a short hang down the mattress end."""
    return [part("Throw top", "rounded", (-690, 690), (-170, 200), (290, 298), "Velvet sage"),
            part("Throw roll", "cylinder", (-24, 24), (-200, -152), (276 - 690, 276 + 690), "Velvet sage", (0, 90, 0)),
            part("Throw drape", "rounded", (-690, 690), (-198, -188), (196, 270), "Velvet sage")]


def pendant_parts():
    """A ceiling pendant: canopy, cord and a fabric shade around the bulb (the lamp emitter is added by make-media.py)."""
    return [part("Canopy", "cylinder", (-60, 60), (-60, 60), (680, 700), "White lacquer"),
            part("Cord", "cylinder", (-5, 5), (-5, 5), (270, 680), "Black metal"),
            part("Holder", "cylinder", (-22, 22), (-22, 22), (230, 290), "Black metal"),
            part("Shade", "taper", (-190, 190), (-190, 190), (80, 290), "Lampshade"),
            part("Bulb", "sphere", (-45, 45), (-45, 45), (120, 210), "White ceramic")]

# design name -> (size, parts); placements: (design, x, y, rotation, z, name)
SHOWCASE = {
    "Leafy plant": ((560, 560, 1450), plant_parts),
    "Bookcase with books": ((800, 320, 1900), bookcase_parts),
    "Curtain panel": ((440, 140, 2400), curtain_panel_parts),
    "Curtain rod": ((2000, 80, 60), curtain_rod_parts),
    "Throw pillows": ((1700, 240, 480), pillow_parts),
    "Coffee table decor": ((600, 240, 260), coffee_decor_parts),
    "Fruit bowl": ((340, 340, 180), fruit_bowl_parts),
    "Kitchen decor": ((560, 200, 360), kitchen_decor_parts),
    "Bed throw": ((1400, 400, 304), throw_parts),
    "Pendant lamp": ((380, 380, 700), pendant_parts),
}
CATEGORY = {"Pendant lamp": "Lighting"}   # the rest is Decor
PLACEMENTS = [
    ("Leafy plant", 420, 560, 0, 0, "Plant living room"),
    ("Leafy plant", 8860, 5300, 0, 0, "Plant bedroom"),
    ("Bookcase with books", 290, 3050, 90, 0, "Bookcase"),
    ("Curtain rod", 1500, 160, 180, 2400, "Curtain rod south 1"),
    ("Curtain rod", 4000, 160, 180, 2400, "Curtain rod south 2"),
    ("Curtain panel", 480, 190, 180, 0, "Curtain south 1 left"),
    ("Curtain panel", 2520, 190, 180, 0, "Curtain south 1 right"),
    ("Curtain panel", 2980, 190, 180, 0, "Curtain south 2 left"),
    ("Curtain panel", 5020, 190, 180, 0, "Curtain south 2 right"),
    ("Throw pillows", 3605, 1700, 270, 430, "Throw pillows"),
    ("Coffee table decor", 2300, 1700, 90, 400, "Coffee table decor"),
    ("Fruit bowl", 2900, 4400, 0, 750, "Fruit bowl"),
    ("Kitchen decor", 3420, 6440, 0, 900, "Kitchen decor"),
    ("Bed throw", 7747, 4350, 90, 360, "Bed throw"),
    ("Pendant lamp", 2900, 4400, 0, 1900, "Pendant dining"),
    ("Pendant lamp", 1920, 5850, 0, 1900, "Pendant kitchen"),
    ("Pendant lamp", 6700, 1250, 0, 1900, "Pendant hallway"),
]


def showcase(c):
    """Nicer surfaces for the palette and own decor designs (plants, books, curtains, pillows, table decor)."""
    c.batch([("material.update", dict(id=palette_id(n), **a)) for n, a in SURFACES.items()])
    c.batch([("material.create", dict(id=uid("mat " + n), name=n, color=col, roughness=r, **extra))
             for n, col, r, extra in DECOR_MATERIALS])
    c.batch([("furniture.create_definition", {"id": uid("design " + n), "name": n, "category": CATEGORY.get(n, "Decor"),
                                              "size": {"width": s[0], "depth": s[1], "height": s[2]}, "components": f()})
             for n, (s, f) in SHOWCASE.items()])
    steps = []
    for design, x, y, rot, z, name in PLACEMENTS:
        pos = pt(x, y)
        if z:
            pos["z"] = z
        steps.append(("furniture.create_instance", {"definitionId": uid("design " + design), "position": pos,
                                                    "rotationDeg": rot, "name": name, "allowsOverlap": True}))
    c.batch(steps)


# ---------------------------------------------------------------- furniture
# Catalog pieces face south at rotation 0, east at 90, north at 180, west at 270.
# (key, x, y, rotation, z, name)
FURNITURE = [
    # living room
    ("tvboard.1600", 330, 1700, 90, 0, "TV board"),
    ("tv.panel.55", 330, 1700, 90, 500, "TV"),
    ("sofa.3seat.2100", 3600, 1700, 270, 0, "Sofa"),
    ("table.coffee.1000", 2300, 1700, 90, 0, "Coffee table"),
    ("lamp.floor", 3800, 420, 0, 0, "Floor lamp"),
    ("rug.2000x3000", 2450, 1700, 90, 0, "Rug"),
    # dining area
    ("table.dining.1600", 2900, 4400, 0, 0, "Dining table"),
    ("chair.dining", 2500, 5100, 0, 0, "Dining chair 1"),
    ("chair.dining", 3300, 5100, 0, 0, "Dining chair 2"),
    ("chair.dining", 2500, 3700, 180, 0, "Dining chair 3"),
    ("chair.dining", 3300, 3700, 180, 0, "Dining chair 4"),
    # open kitchen along the north wall
    ("fridge.600", 420, 6315, 0, 0, "Refrigerator"),
    ("kitchen.base.600", 1020, 6340, 0, 0, "Kitchen base cabinet 1"),
    ("kitchen.sink.1200", 1920, 6340, 0, 0, "Kitchen sink"),
    ("stove.600", 2820, 6340, 0, 0, "Cooker"),
    ("kitchen.base.600", 3420, 6340, 0, 0, "Kitchen base cabinet 2"),
    ("kitchen.wall.600", 1020, 6465, 0, 1400, "Kitchen wall cabinet 1"),
    ("kitchen.wall.600", 3420, 6465, 0, 1400, "Kitchen wall cabinet 2"),
    # hallway
    ("hallunit.900", 6032, 1990, 90, 0, "Hall unit"),
    # bathroom
    ("bath.shower.900", 8690, 570, 0, 0, "Shower"),
    ("bath.washbasin.600", 8700, 2202, 0, 0, "Washbasin"),
    ("bath.toilet", 7950, 2092, 0, 0, "Toilet"),
    # bedroom
    ("bed.double.1600", 6913, 4350, 90, 0, "Bed"),
    ("nightstand.450", 6058, 3235, 90, 0, "Nightstand left"),
    ("nightstand.450", 6058, 5465, 90, 0, "Nightstand right"),
    ("lamp.table", 6058, 3235, 0, 500, "Table lamp left"),
    ("lamp.table", 6058, 5465, 0, 500, "Table lamp right"),
    ("wardrobe.2000", 8000, 6338, 0, 0, "Wardrobe"),
    ("dresser.4drawer.900", 8890, 3015, 270, 0, "Dresser"),
]

MATERIALS = [  # name, colour, roughness
    ("Oak parquet", "#C9A06C", 0.5),
    ("Light tiles", "#D8DCDF", 0.3),
    ("Hallway stone", "#B9B3AA", 0.4),
    ("Wall white", "#F4F1EA", 0.9),
    ("Accent sage", "#A9B8A0", 0.9),
    ("Outer plaster", "#E4DED2", 0.9),
]

ROOMS = [  # name, point inside the closed wall loop, floor material
    ("Living room", (2800, 3000), "Oak parquet"),
    ("Hallway", (6700, 1250), "Hallway stone"),
    ("Bathroom", (8400, 1250), "Light tiles"),
    ("Bedroom", (7500, 4500), "Oak parquet"),
]


def build(c, out_dir, images):
    c.call("project.new", discard=True)
    c.call("project.update_settings", name="Demo Apartment")

    # materials first so that later steps can refer to them by name
    c.batch([("material.create", {"id": uid("mat " + n), "name": n, "color": col, "roughness": r})
             for n, col, r in MATERIALS])

    # walls
    c.batch([("geometry.create_wall", {"id": uid("wall " + n), "start": pt(*a), "end": pt(*b),
                                       "thicknessMm": t, "heightMm": 2600})
             for n, (a, b, t) in WALLS.items()])
    inner = [uid("wall " + n) for n, w in WALLS.items() if w[2] == INNER]
    outer = [uid("wall " + n) for n, w in WALLS.items() if w[2] == OUTER]
    c.batch([("scene.set_material", {"ids": inner, "slot": "wallBoth", "material": "Wall white"}),
             ("scene.set_material", {"ids": outer, "slot": "wallRight", "material": "Outer plaster"}),
             ("scene.set_material", {"ids": outer, "slot": "wallLeft", "material": "Wall white"})])

    # doors and windows
    steps = []
    for wall, typ, off, w, h, sill, name, inward in OPENINGS:
        args = {"id": uid("opening " + name), "wallId": uid("wall " + wall), "type": typ,
                "offsetMm": off, "widthMm": w, "heightMm": h, "name": name}
        if sill is not None:
            args["sillMm"] = sill
        steps.append(("geometry.add_opening", args))
        if inward is not None:
            steps.append(("geometry.update_opening", {"id": args["id"], "inward": inward}))
    c.batch(steps)

    # rooms from the wall loops, with floors
    for name, p, floor in ROOMS:
        c.call("geometry.create_room_from_walls", id=uid("room " + name), name=name, point=pt(*p))
    c.batch([("geometry.update_room", {"id": uid("room " + n), "floorMaterial": f}) for n, _, f in ROOMS])
    # bathroom wall tiles on the shower side and the washbasin side
    c.batch([("geometry.update_wall", {"id": uid("wall V2"), "rightMaterial": "Light tiles"}),
             ("geometry.update_wall", {"id": uid("wall H1b"), "rightMaterial": "Light tiles"}),
             ("geometry.update_wall", {"id": uid("wall V1b"), "rightMaterial": "Accent sage"})])

    # furniture
    steps = []
    for n, (key, x, y, rot, z, name) in enumerate(FURNITURE):
        pos = pt(x, y)
        if z:
            pos["z"] = z
        steps.append(("catalog.insert_builtin", {"key": key, "position": pos, "rotationDeg": rot,
                                                 "name": name}))
    c.batch(steps)
    showcase(c)

    # dimension chains on the outer walls (outer faces; offset is signed: positive = left of the direction)
    c.call("geometry.dimension_chain", points=[pt(-120, -120), pt(5800, -120), pt(7600, -120), pt(9380, -120)],
           offsetMm=-500)
    c.call("geometry.dimension_chain", points=[pt(9380, -120), pt(9380, 2500), pt(9380, 6880)], offsetMm=-500)
    c.call("geometry.dimension_chain", points=[pt(-120, -120), pt(-120, 6880)], offsetMm=500)

    # saved camera views
    c.call("camera.save", name="Living room", mode="orbit", target=dict(pt(1800, 3300), z=800),
           distanceMm=4800, yawDeg=120, pitchDeg=-18, fovDeg=65)
    c.call("camera.save", name="Aerial", mode="orbit", target=dict(pt(4630, 3380), z=0),
           distanceMm=15000, yawDeg=20, pitchDeg=-50, fovDeg=45)

    # checks
    coll = c.call("scene.check_collisions")
    clear = c.call("report.clearances", format="json")
    print("collisions:", coll["total"])
    for it in coll["items"]:
        print("  ", it)
    kinds = {}
    for f in clear["findings"]:
        kinds[f["kind"]] = kinds.get(f["kind"], 0) + 1
    print("clearance findings:", clear["count"], kinds)
    for f in clear["findings"]:  # wall/furniture gaps are intended (pieces stand against walls)
        if f["overlaps"] or f["kind"] in ("doorSwing", "doorApproach"):
            print("  ", f["kind"], f["instanceId"], f["otherId"], f["distanceMm"])
    if images:
        os.makedirs(images, exist_ok=True)
        c.call("render.plan_image", path=os.path.join(images, "plan.png"), overwrite=True,
               paper="A3", scale="fit", dpi=150)
        c.call("render.scene_image", path=os.path.join(images, "aerial.png"), overwrite=True,
               width=1600, height=1000, camera={"mode": "orbit", "target": dict(pt(4630, 3380), z=0),
                                                "distanceMm": 15000, "yawDeg": 20, "pitchDeg": -50,
                                                "fovDeg": 45})

    os.makedirs(out_dir, exist_ok=True)
    target = os.path.join(os.path.abspath(out_dir), "Demo Apartment.roomsmith")
    res = c.call("project.save_as", path=target, overwrite=True)
    print("saved:", res["path"])
    summary = c.call("project.get_summary")
    print("summary:", json.dumps(summary)[:600])


def main():
    ap = argparse.ArgumentParser(description="Build the Demo Apartment example through the agent API.")
    ap.add_argument("mcp", help="path to the roomsmith-mcp program")
    ap.add_argument("out", help="folder that receives 'Demo Apartment.roomsmith'")
    ap.add_argument("--images", help="optional folder for plan.png and aerial.png of the result")
    args = ap.parse_args()
    c = Client(args.mcp)
    try:
        build(c, args.out, args.images)
    finally:
        c.close()


if __name__ == "__main__":
    main()
