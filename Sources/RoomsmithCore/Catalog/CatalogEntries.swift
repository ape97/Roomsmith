import Foundation

extension BuiltinCatalog {
    typealias Build = @Sendable (inout PartBuilder) -> Void

    private static func entry(_ key: String, _ name: String, _ category: String, _ tags: [String], _ size: Size3,
                              _ build: @escaping Build) -> CatalogEntry {
        CatalogEntry(key: key, name: name, category: category, tags: tags) {
            var b = PartBuilder(key: key, size: size)
            build(&b)
            return b.finish(name: name, category: category, tags: tags)
        }
    }

    private static func parametric(_ key: String, _ name: String, _ category: String, _ tags: [String],
                                   _ make: @escaping @Sendable () -> FurnitureDefinition) -> CatalogEntry {
        CatalogEntry(key: key, name: name, category: category, tags: tags, make: make)
    }

    static func makeEntries() -> [CatalogEntry] {
        living() + modularSofa() + bedroom() + kitchen() + bathroom() + office() + dining() + decor() + lighting()
    }

    // MARK: Living

    private static func living() -> [CatalogEntry] {
        [
            parametric("sofa.3seat.2100", "Sofa – 3 seater", "Living", ["sofa", "couch", "seating"]) {
                ParametricBuilder.sofa(key: "sofa.3seat.2100", name: "", category: "", size: Size3(2100, 950, 850), armWidth: 180,
                                       seatHeight: 430, materialId: Palette.greyFabric.id)
            },
            parametric("sofa.2seat.1600", "Sofa – 2 seater", "Living", ["sofa", "couch", "seating"]) {
                ParametricBuilder.sofa(key: "sofa.2seat.1600", name: "", category: "", size: Size3(1600, 900, 820), armWidth: 160,
                                       seatHeight: 430, materialId: Palette.beigeFabric.id)
            },
            parametric("armchair.800", "Armchair", "Living", ["armchair", "chair", "seating"]) {
                ParametricBuilder.sofa(key: "armchair.800", name: "", category: "", size: Size3(800, 850, 850), armWidth: 150,
                                       seatHeight: 430, materialId: Palette.leather.id)
            },
            parametric("table.coffee.1000", "Coffee table", "Living", ["table", "coffee table", "couch table"]) {
                ParametricBuilder.table(key: "table.coffee.1000", name: "", category: "", size: Size3(1000, 600, 400), legInset: 40,
                                        topThickness: 30, materialId: Palette.walnut.id)
            },
            parametric("tvboard.1600", "TV board", "Living", ["tv", "board", "sideboard", "cabinet", "lowboard"]) {
                ParametricBuilder.cabinet(key: "tvboard.1600", name: "", category: "", size: Size3(1600, 420, 500), shelves: 1, doors: 3,
                                          plinth: 100, materialId: Palette.oak.id)
            },
            entry("tv.panel.55", "TV (panel)", "Living", ["tv", "television", "screen", "55 inch"], Size3(1240, 200, 780)) { b in
                b.add("Foot", x: -260 ... 260, y: -100 ... 100, z: 0 ... 12, Palette.blackMetal)
                b.add("Neck", x: -40 ... 40, y: 20 ... 60, z: 12 ... 70, Palette.blackMetal)
                b.add("Panel", x: -620 ... 620, y: 20 ... 60, z: 70 ... 780, Palette.blackPlastic)
                b.add("Screen", x: -610 ... 610, y: 16 ... 20, z: 80 ... 770, Palette.screen)
            },
            parametric("bookcase.800", "Bookcase", "Living", ["bookcase", "shelf", "books", "storage"]) {
                ParametricBuilder.shelf(key: "bookcase.800", name: "", category: "", size: Size3(800, 300, 1900), boards: 6,
                                        materialId: Palette.birch.id)
            },
            entry("hallunit.900", "Hall unit with coat hooks", "Living", ["hall", "entry", "coat rack", "garderobe", "shoe bench"],
                  Size3(900, 350, 1900)) { b in
                let hw = b.hw, hd = b.hd, o = Palette.oak
                b.add("Side left", x: -hw ... (-hw + 18), y: -hd ... hd, z: 0 ... 432, o)
                b.add("Side right", x: (hw - 18) ... hw, y: -hd ... hd, z: 0 ... 432, o)
                b.add("Divider", x: -9 ... 9, y: -hd ... hd, z: 0 ... 432, o)
                b.add("Seat", x: -hw ... hw, y: -hd ... hd, z: 432 ... 450, o)
                b.add("Lower shelf", x: (-hw + 18) ... (hw - 18), y: (-hd + 2) ... (hd - 2), z: 150 ... 168, o)
                b.add("Back board", x: -hw ... hw, y: (hd - 20) ... hd, z: 450 ... 1900, o)
                b.add("Hat shelf", x: -hw ... hw, y: -hd ... (hd - 20), z: 1790 ... 1810, o)
                b.add("Hook rail", x: (-hw + 60) ... (hw - 60), y: (hd - 40) ... (hd - 20), z: 1500 ... 1560, Palette.blackMetal)
                for i in 0..<5 {
                    let cx = -300 + MM(i) * 150
                    b.add("Hook \(i + 1)", x: (cx - 10) ... (cx + 10), y: (hd - 90) ... (hd - 40), z: 1530 ... 1550, Palette.blackMetal)
                }
            },
        ]
    }

    // MARK: Modular sofa modules

    private static func modularSofa() -> [CatalogEntry] {
        let m = Palette.greyFabric.id
        func module(_ key: String, _ name: String, _ size: Size3, left: MM, right: MM) -> CatalogEntry {
            entry(key, name, "Living", ["sofa", "modular", "couch", "seating"], size) { b in
                BuiltinCatalog.upholsteredModule(&b, armLeft: left, armRight: right, material: m)
            }
        }
        return [
            entry(ModularSofaKey.corner, "Modular sofa – corner", "Living", ["sofa", "modular", "corner", "couch", "seating"],
                  Size3(950, 950, 850)) { b in
                let hw = b.hw, hd = b.hd
                let backT: MM = 220, cushT: MM = 140, seatTop: MM = 430
                for (xn, xr) in [("left", (-hw + 40) ... (-hw + 90)), ("right", (hw - 90) ... (hw - 40))] {
                    for (yn, yr) in [("front", (-hd + 40) ... (-hd + 90)), ("back", (hd - 90) ... (hd - 40))] {
                        b.add("Foot \(yn) \(xn)", x: xr, y: yr, z: 0 ... 100, Palette.blackMetal)
                    }
                }
                b.add("Base", x: -hw ... hw, y: -hd ... hd, z: 100 ... (seatTop - cushT), m)
                b.add("Backrest rear", .cushion, x: -hw ... hw, y: (hd - backT) ... hd, z: 100 ... 850, m)
                b.add("Backrest side", .cushion, x: -hw ... (-hw + backT), y: -hd ... (hd - backT), z: 100 ... 850, m)
                b.add("Seat cushion", .cushion, x: (-hw + backT) ... hw, y: -hd ... (hd - backT), z: (seatTop - cushT) ... seatTop, m)
                b.add("Back cushion rear", .cushion, x: (-hw + backT) ... hw, y: (hd - backT - 120) ... (hd - backT), z: seatTop ... 790, m)
                b.add("Back cushion side", .cushion, x: (-hw + backT) ... (-hw + backT + 120), y: -hd ... (hd - backT - 120),
                      z: seatTop ... 790, m)
            },
            module(ModularSofaKey.middle, "Modular sofa – middle (2-seat)", Size3(1400, 950, 850), left: 0, right: 0),
            module(ModularSofaKey.endLeft, "Modular sofa – end, left arm", Size3(1580, 950, 850), left: 180, right: 0),
            module(ModularSofaKey.endRight, "Modular sofa – end, right arm", Size3(1580, 950, 850), left: 0, right: 180),
            entry(ModularSofaKey.ottoman, "Modular sofa – ottoman", "Living", ["sofa", "modular", "ottoman", "footstool", "seating"],
                  Size3(900, 650, 430)) { b in
                let hw = b.hw, hd = b.hd
                for (xn, xr) in [("left", (-hw + 40) ... (-hw + 90)), ("right", (hw - 90) ... (hw - 40))] {
                    for (yn, yr) in [("front", (-hd + 40) ... (-hd + 90)), ("back", (hd - 90) ... (hd - 40))] {
                        b.add("Foot \(yn) \(xn)", x: xr, y: yr, z: 0 ... 60, Palette.blackMetal)
                    }
                }
                b.add("Cushion", .cushion, x: -hw ... hw, y: -hd ... hd, z: 60 ... 430, m)
            },
        ]
    }

    fileprivate static func upholsteredModule(_ b: inout PartBuilder, armLeft: MM, armRight: MM, material: UUID) {
        ParametricBuilder.upholsteredParts(&b, armLeft: armLeft, armRight: armRight, seatHeight: 430, material: material)
    }

    // MARK: Bedroom

    private static func bed(_ b: inout PartBuilder, pillows: Int) {
        let hw = b.hw, hd = b.hd, H = b.h
        let mhw = (b.size.width - 140) / 2
        for (xn, xr) in [("left", (-hw) ... (-hw + 60)), ("right", (hw - 60) ... hw)] {
            for (yn, yr) in [("front", (-hd) ... (-hd + 60)), ("back", (hd - 60) ... hd)] {
                b.add("Foot \(yn) \(xn)", x: xr, y: yr, z: 0 ... 100, Palette.walnut)
            }
        }
        b.add("Frame", x: -hw ... hw, y: -hd ... (hd - 40), z: 100 ... 350, Palette.oak)
        b.add("Headboard", .cushion, x: -hw ... hw, y: (hd - 40) ... hd, z: 100 ... H, Palette.greyFabric)
        b.add("Mattress", .cushion, x: -mhw ... mhw, y: (-hd + 35) ... (-hd + 2035), z: 350 ... 600, Palette.linen)
        b.add("Duvet", .cushion, x: -mhw ... mhw, y: (-hd + 35) ... 300, z: 600 ... 650, Palette.beigeFabric)
        let n = max(1, pillows)
        let slot = 2 * mhw / MM(n)
        let pw = min(600, slot - 100)
        for i in 0..<n {
            let cx = -mhw + slot * MM(2 * i + 1) / 2
            b.add("Pillow \(i + 1)", .cushion, x: (cx - pw / 2) ... (cx + pw / 2), y: 540 ... 940, z: 600 ... 720, Palette.linen)
        }
    }

    private static func bedroom() -> [CatalogEntry] {
        [
            entry("bed.double.1600", "Double bed 160 x 200", "Bedroom", ["bed", "double bed", "sleeping"], Size3(1740, 2110, 1000)) { b in
                bed(&b, pillows: 2)
            },
            entry("bed.single.900", "Single bed 90 x 200", "Bedroom", ["bed", "single bed", "sleeping"], Size3(1040, 2110, 950)) { b in
                bed(&b, pillows: 1)
            },
            parametric("nightstand.450", "Nightstand", "Bedroom", ["nightstand", "bedside table", "cabinet"]) {
                ParametricBuilder.cabinet(key: "nightstand.450", name: "", category: "", size: Size3(450, 400, 500), shelves: 1, doors: 1,
                                          plinth: 100, materialId: Palette.walnut.id)
            },
            parametric("wardrobe.1000", "Wardrobe 2 doors", "Bedroom", ["wardrobe", "closet", "cabinet", "storage"]) {
                ParametricBuilder.cabinet(key: "wardrobe.1000", name: "", category: "", size: Size3(1000, 600, 2100), shelves: 4, doors: 2,
                                          plinth: 80, materialId: Palette.whiteLacquer.id)
            },
            parametric("wardrobe.2000", "Wardrobe 4 doors", "Bedroom", ["wardrobe", "closet", "cabinet", "storage"]) {
                ParametricBuilder.cabinet(key: "wardrobe.2000", name: "", category: "", size: Size3(2000, 600, 2200), shelves: 4, doors: 4,
                                          plinth: 80, materialId: Palette.whiteLacquer.id)
            },
            entry("dresser.4drawer.900", "Dresser with 4 drawers", "Bedroom", ["dresser", "chest of drawers", "commode", "drawers", "storage"],
                  Size3(900, 480, 850)) { b in
                let hw = b.hw, hd = b.hd, H = b.h, t: MM = 18, front = -hd + 30, w = Palette.walnut
                b.add("Side left", x: -hw ... (-hw + t), y: front ... hd, z: 70 ... H, w)
                b.add("Side right", x: (hw - t) ... hw, y: front ... hd, z: 70 ... H, w)
                b.add("Top", x: (-hw + t) ... (hw - t), y: front ... hd, z: (H - t) ... H, w)   // between the sides: no coplanar overlap
                b.add("Bottom", x: (-hw + t) ... (hw - t), y: front ... hd, z: 70 ... (70 + t), w)
                b.add("Back", x: (-hw + t) ... (hw - t), y: (hd - 6) ... hd, z: 88 ... (H - t), w)
                b.add("Plinth", x: (-hw + t) ... (hw - t), y: (front + 20) ... (hd - 20), z: 0 ... 70, Palette.blackMetal)
                b.state("closed", asDefault: true)
                b.state("open", size: Size3(900, 880, 850))
                b.durationMs = 500
                for i in 0..<4 {
                    let z0 = 90 + MM(i) * 185, zc = z0 + 90
                    let parts = [
                        b.add("Drawer \(i + 1) front", x: (-hw + t + 2) ... (hw - t - 2), y: (-hd + 12) ... (-hd + 30), z: z0 ... (z0 + 180), w),
                        b.add("Drawer \(i + 1) handle", x: -60 ... 60, y: -hd ... (-hd + 12), z: (zc - 8) ... (zc + 8), Palette.chrome),
                        b.add("Drawer \(i + 1) body", x: (-hw + t + 12) ... (hw - t - 12), y: front ... (hd - 20), z: (z0 + 10) ... (z0 + 170),
                              Palette.birch),
                    ]
                    if i == 3 {
                        for id in parts {
                            let p = b.position(of: id)
                            b.pose("open", id, position: P3(p.x, p.y - 400, p.z))
                        }
                    }
                }
            },
            wallBed(),
        ]
    }

    /// Wall bed: 1400 x 2000 sleeping surface, hinged at the lower front edge of the carcass.
    /// Base geometry is the folded state (sleeping surface upright inside the carcass); `unfolded` rotates it exactly 90° forward.
    private static func wallBed() -> CatalogEntry {
        entry("bed.wall.1400", "Wall bed", "Bedroom", ["bed", "wall bed", "fold", "folding", "murphy", "sleeping"], Size3(1500, 450, 2200)) { b in
            let hw = b.hw, hd = b.hd
            let pivot = P3(0, -hd, 100)
            let body = Palette.whiteLacquer
            // Even wall thickness: an odd one puts the part centre on a half millimetre, which Int64 mm rounds into the neighbours.
            let t: MM = 26
            b.add("Side left", x: -hw ... (-hw + t), y: -hd ... hd, z: 0 ... 2200, body)
            b.add("Side right", x: (hw - t) ... hw, y: -hd ... hd, z: 0 ... 2200, body)
            b.add("Top", x: (-hw + t) ... (hw - t), y: -hd ... hd, z: 2150 ... 2200, body)
            b.add("Base", x: (-hw + t) ... (hw - t), y: -hd ... hd, z: 0 ... 100, body)
            b.add("Back", x: (-hw + t) ... (hw - t), y: (hd - 18) ... hd, z: 100 ... 2150, Palette.birch)
            let frame = b.add("Frame", x: -700 ... 700, y: (-hd + 20) ... (-hd + 80), z: 100 ... 2100, Palette.oak, pivot: pivot)
            let mattress = b.add("Mattress", .cushion, x: -700 ... 700, y: (-hd + 80) ... (-hd + 280), z: 100 ... 2100, Palette.linen, pivot: pivot)
            let footLeft = b.add("Foot left", x: -680 ... -620, y: -hd ... (-hd + 20), z: 2000 ... 2100, Palette.blackMetal)
            let footRight = b.add("Foot right", x: 620 ... 680, y: -hd ... (-hd + 20), z: 2000 ... 2100, Palette.blackMetal)
            b.state("folded", size: Size3(1500, 450, 2200), asDefault: true)
            b.state("unfolded", size: Size3(1500, 2450, 2200))
            b.durationMs = 1200
            let flat = R3(90, 0, 0)
            b.pose("unfolded", frame, rotation: flat)
            b.pose("unfolded", mattress, rotation: flat)
            b.pose("unfolded", footLeft, position: P3(-650, -hd - 1970, 60), size: Size3(60, 60, 120))
            b.pose("unfolded", footRight, position: P3(650, -hd - 1970, 60), size: Size3(60, 60, 120))
        }
    }

    // MARK: Kitchen

    private static func worktop(_ b: inout PartBuilder, z: ClosedRange<MM>) {
        b.add("Worktop", x: -b.hw ... b.hw, y: -b.hd ... b.hd, z: z, Palette.stone)
    }

    private static func kitchen() -> [CatalogEntry] {
        [
            entry("kitchen.base.600", "Kitchen base cabinet 60", "Kitchen", ["kitchen", "base cabinet", "lower cabinet", "cabinet"],
                  Size3(600, 600, 900)) { b in
                ParametricBuilder.cabinetParts(&b, height: 870, shelves: 1, doors: 1, plinth: 100, material: Palette.whiteLacquer.id)
                worktop(&b, z: 870 ... 900)
            },
            entry("kitchen.wall.600", "Kitchen wall cabinet 60", "Kitchen", ["kitchen", "wall cabinet", "upper cabinet", "cabinet", "wall-mounted"],
                  Size3(600, 350, 720)) { b in
                ParametricBuilder.cabinetParts(&b, height: 720, shelves: 1, doors: 1, plinth: 0, material: Palette.whiteLacquer.id)
            },
            entry("fridge.600", "Refrigerator with freezer", "Kitchen", ["kitchen", "fridge", "refrigerator", "freezer", "appliance"],
                  Size3(600, 650, 1850)) { b in
                let hw = b.hw, hd = b.hd
                b.add("Body", x: -hw ... hw, y: (-hd + 32) ... hd, z: 0 ... 1850, Palette.whiteLacquer)
                let yMid = -hd + 22
                let lowerPivot = P3(-hw, yMid, 635), upperPivot = P3(-hw, yMid, 1550)
                let door = b.add("Fridge door", x: -hw ... hw, y: (-hd + 12) ... (-hd + 32), z: 20 ... 1250, Palette.stainless, pivot: lowerPivot)
                let handle = b.add("Fridge handle", x: (hw - 40) ... (hw - 28), y: -hd ... (-hd + 12), z: 900 ... 1200, Palette.chrome,
                                   pivot: lowerPivot)
                let freezerDoor = b.add("Freezer door", x: -hw ... hw, y: (-hd + 12) ... (-hd + 32), z: 1254 ... 1846, Palette.stainless,
                                        pivot: upperPivot)
                let freezerHandle = b.add("Freezer handle", x: (hw - 40) ... (hw - 28), y: -hd ... (-hd + 12), z: 1260 ... 1420, Palette.chrome,
                                          pivot: upperPivot)
                b.state("closed", asDefault: true)
                b.state("open")
                b.durationMs = 700
                b.pose("open", door, rotation: R3(0, 0, -100))
                b.pose("open", handle, rotation: R3(0, 0, -100))
                b.pose("open", freezerDoor, rotation: R3(0, 0, -100))
                b.pose("open", freezerHandle, rotation: R3(0, 0, -100))
            },
            entry("stove.600", "Cooker with oven", "Kitchen", ["kitchen", "stove", "cooker", "oven", "hob", "appliance"], Size3(600, 600, 900)) { b in
                let hw = b.hw, hd = b.hd, s = Palette.stainless
                b.add("Body", x: -hw ... hw, y: (-hd + 22) ... hd, z: 0 ... 880, Palette.whiteLacquer)
                b.add("Kick panel", x: -hw ... hw, y: (-hd + 10) ... (-hd + 22), z: 0 ... 80, Palette.blackMetal)
                b.add("Control panel", x: -hw ... hw, y: (-hd + 10) ... (-hd + 22), z: 700 ... 880, s)
                b.add("Frame left", x: -hw ... (-hw + 20), y: (-hd + 10) ... (-hd + 22), z: 80 ... 700, s)
                b.add("Frame right", x: (hw - 20) ... hw, y: (-hd + 10) ... (-hd + 22), z: 80 ... 700, s)
                let pivot = P3(0, -hd + 16, 80)
                let door = b.add("Oven door", x: (-hw + 20) ... (hw - 20), y: (-hd + 10) ... (-hd + 22), z: 80 ... 700, s, pivot: pivot)
                let window = b.add("Oven window", x: (-hw + 80) ... (hw - 80), y: (-hd + 6) ... (-hd + 10), z: 160 ... 560, Palette.screen, pivot: pivot)
                let handle = b.add("Oven handle", x: (-hw + 60) ... (hw - 60), y: -hd ... (-hd + 10), z: 630 ... 654, Palette.chrome, pivot: pivot)
                b.add("Hob", x: -hw ... hw, y: -hd ... hd, z: 880 ... 890, Palette.screen)
                for (i, c) in [(-150, -110, 180), (150, -110, 140), (-150, 110, 140), (150, 110, 180)].enumerated() {
                    let r = MM(c.2) / 2
                    b.add("Burner \(i + 1)", .cylinder, x: (MM(c.0) - r) ... (MM(c.0) + r), y: (MM(c.1) - r) ... (MM(c.1) + r), z: 890 ... 894, Palette.chrome)
                }
                b.state("closed", asDefault: true)
                b.state("open")
                b.durationMs = 600
                for id in [door, window, handle] { b.pose("open", id, rotation: R3(90, 0, 0)) }
            },
            entry("kitchen.sink.1200", "Kitchen sink unit 120", "Kitchen", ["kitchen", "sink", "base cabinet", "tap"], Size3(1200, 600, 1060)) { b in
                let hw = b.hw
                ParametricBuilder.cabinetParts(&b, height: 870, shelves: 0, doors: 2, plinth: 100, material: Palette.whiteLacquer.id)
                let st = Palette.stone
                b.add("Worktop left", x: -hw ... -330, y: -300 ... 300, z: 870 ... 900, st)
                b.add("Worktop right", x: 330 ... hw, y: -300 ... 300, z: 870 ... 900, st)
                b.add("Worktop front", x: -330 ... 330, y: -300 ... -190, z: 870 ... 900, st)
                b.add("Worktop back", x: -330 ... 330, y: 190 ... 300, z: 870 ... 900, st)
                b.add("Basin", x: -330 ... 330, y: -190 ... 190, z: 870 ... 876, Palette.stainless)
                b.add("Tap column", .cylinder, x: -15 ... 15, y: 225 ... 255, z: 900 ... 1040, Palette.chrome)
                b.add("Tap spout", x: -10 ... 10, y: 150 ... 255, z: 1020 ... 1040, Palette.chrome)
            },
        ]
    }

    // MARK: Bathroom

    private static func bathroom() -> [CatalogEntry] {
        [
            entry("bath.tub.1700", "Bathtub 170", "Bathroom", ["bathroom", "bathtub", "bath", "tub"], Size3(1700, 750, 640)) { b in
                let hw = b.hw, hd = b.hd, c = Palette.ceramic
                b.add("Floor", x: -hw ... hw, y: -hd ... hd, z: 0 ... 120, c)
                b.add("End left", x: -hw ... (-hw + 60), y: -hd ... hd, z: 120 ... 560, c)
                b.add("End right", x: (hw - 60) ... hw, y: -hd ... hd, z: 120 ... 560, c)
                b.add("Side front", x: (-hw + 60) ... (hw - 60), y: -hd ... (-hd + 60), z: 120 ... 560, c)
                b.add("Side back", x: (-hw + 60) ... (hw - 60), y: (hd - 60) ... hd, z: 120 ... 560, c)
                b.add("Tap column", .cylinder, x: -840 ... -800, y: -20 ... 20, z: 560 ... 640, Palette.chrome)
                b.add("Tap spout", x: -800 ... -700, y: -15 ... 15, z: 610 ... 640, Palette.chrome)
            },
            entry("bath.shower.900", "Shower enclosure 90 x 90", "Bathroom", ["bathroom", "shower", "glass"], Size3(900, 900, 2000)) { b in
                let hw = b.hw, hd = b.hd
                b.add("Tray", x: -hw ... hw, y: -hd ... hd, z: 0 ... 60, Palette.ceramic)
                b.add("Glass left", x: -hw ... (-hw + 8), y: -hd ... hd, z: 60 ... 1980, Palette.glass)
                b.add("Glass front", x: (-hw + 8) ... hw, y: -hd ... (-hd + 8), z: 60 ... 1980, Palette.glass)
                b.add("Rail front", x: -hw ... hw, y: -hd ... (-hd + 12), z: 1980 ... 2000, Palette.chrome)
                b.add("Rail left", x: -hw ... (-hw + 12), y: (-hd + 12) ... hd, z: 1980 ... 2000, Palette.chrome)
                b.add("Shower pole", .cylinder, x: (hw - 115) ... (hw - 85), y: (hd - 45) ... (hd - 15), z: 60 ... 1960, Palette.chrome)
                b.add("Shower arm", x: (hw - 110) ... (hw - 90), y: (hd - 100) ... (hd - 45), z: 1940 ... 1960, Palette.chrome)
                b.add("Shower head", .cylinder, x: (hw - 180) ... (hw - 20), y: (hd - 180) ... (hd - 20), z: 1920 ... 1940, Palette.chrome)
            },
            entry("bath.toilet", "Toilet", "Bathroom", ["bathroom", "toilet", "wc"], Size3(380, 700, 800)) { b in
                let c = Palette.ceramic
                b.add("Rear body", x: -150 ... 150, y: 160 ... 350, z: 0 ... 380, c)
                b.add("Pedestal", x: -90 ... 90, y: -100 ... 160, z: 0 ... 300, c)
                b.add("Bowl", .cushion, x: -190 ... 190, y: -350 ... 170, z: 300 ... 400, c)
                b.add("Seat", .panel, x: -170 ... 170, y: -340 ... 100, z: 400 ... 416, Palette.whiteLacquer)
                b.add("Lid", .panel, x: -165 ... 165, y: -335 ... 95, z: 416 ... 428, Palette.whiteLacquer)
                b.add("Cistern", x: -190 ... 190, y: 160 ... 350, z: 380 ... 790, c)
                b.add("Flush button", x: -40 ... 40, y: 230 ... 290, z: 790 ... 800, Palette.chrome)
            },
            entry("bath.washbasin.600", "Washbasin with vanity unit", "Bathroom", ["bathroom", "washbasin", "sink", "vanity", "tap"],
                  Size3(600, 480, 900)) { b in
                ParametricBuilder.cabinetParts(&b, height: 780, shelves: 1, doors: 1, plinth: 100, material: Palette.oak.id)
                b.add("Counter", x: -b.hw ... b.hw, y: -b.hd ... b.hd, z: 780 ... 810, Palette.ceramic)
                b.add("Basin", .cushion, x: -220 ... 220, y: -190 ... 170, z: 810 ... 830, Palette.ceramic)
                b.add("Tap column", .cylinder, x: -15 ... 15, y: 195 ... 225, z: 810 ... 880, Palette.chrome)
                b.add("Tap spout", x: -10 ... 10, y: 140 ... 225, z: 860 ... 880, Palette.chrome)
            },
        ]
    }

    // MARK: Office

    private static func office() -> [CatalogEntry] {
        [
            entry("desk.1400", "Desk with drawer unit", "Office", ["desk", "office", "table", "drawers", "workspace"], Size3(1400, 700, 740)) { b in
                let hw = b.hw, hd = b.hd, o = Palette.oak
                b.add("Top", x: -hw ... hw, y: -hd ... hd, z: 710 ... 740, o)
                b.add("Side panel", x: (-hw + 20) ... (-hw + 38), y: (-hd + 40) ... (hd - 40), z: 0 ... 710, o)
                b.add("Modesty panel", x: (-hw + 38) ... (hw - 420), y: (hd - 60) ... (hd - 42), z: 300 ... 700, o)
                b.add("Drawer unit", x: (hw - 420) ... (hw - 20), y: (-hd + 52) ... (hd - 20), z: 0 ... 710, Palette.whiteLacquer)
                let cx = hw - 220
                for i in 0..<3 {
                    let z0 = 10 + MM(i) * 232, zc = z0 + 113
                    b.add("Drawer \(i + 1) front", x: (cx - 195) ... (cx + 195), y: (-hd + 40) ... (-hd + 52), z: z0 ... (z0 + 226), o)
                    b.add("Drawer \(i + 1) handle", x: (cx - 60) ... (cx + 60), y: (-hd + 28) ... (-hd + 40), z: (zc - 8) ... (zc + 8), Palette.chrome)
                }
            },
            entry("chair.office", "Office chair", "Office", ["chair", "office chair", "swivel", "seating", "desk chair"], Size3(600, 600, 1000)) { b in
                let m = Palette.blackPlastic
                for (i, c) in [(250, 0), (-250, 0), (0, 250), (0, -250)].enumerated() {
                    b.add("Caster \(i + 1)", .cylinder, x: (MM(c.0) - 25) ... (MM(c.0) + 25), y: (MM(c.1) - 25) ... (MM(c.1) + 25), z: 0 ... 50, m)
                }
                b.add("Base arm X", x: -270 ... 270, y: -30 ... 30, z: 50 ... 80, m)
                b.add("Base arm Y front", x: -30 ... 30, y: -270 ... -30, z: 50 ... 80, m)
                b.add("Base arm Y back", x: -30 ... 30, y: 30 ... 270, z: 50 ... 80, m)
                b.add("Column", .cylinder, x: -30 ... 30, y: -30 ... 30, z: 80 ... 400, Palette.chrome)
                b.add("Seat", .cushion, x: -250 ... 250, y: -250 ... 250, z: 400 ... 460, Palette.greyFabric)
                b.add("Back support", x: -30 ... 30, y: 230 ... 280, z: 460 ... 500, m)
                b.add("Backrest", .cushion, x: -230 ... 230, y: 230 ... 280, z: 500 ... 980, Palette.greyFabric)
                for (n, sign) in [("left", MM(-1)), ("right", MM(1))] {
                    let a = sign * 255, bx = sign * 285
                    b.add("Arm post \(n)", x: min(a, bx) ... max(a, bx), y: 0 ... 30, z: 460 ... 560, m)
                    b.add("Armrest \(n)", x: min(sign * 245, sign * 295) ... max(sign * 245, sign * 295), y: -120 ... 180, z: 560 ... 590, m)
                }
            },
        ]
    }

    // MARK: Dining

    private static func dining() -> [CatalogEntry] {
        [
            parametric("table.dining.1600", "Dining table", "Dining", ["table", "dining table", "dining"]) {
                ParametricBuilder.table(key: "table.dining.1600", name: "", category: "", size: Size3(1600, 900, 750), legInset: 60,
                                        topThickness: 30, materialId: Palette.oak.id)
            },
            entry("chair.dining", "Dining chair", "Dining", ["chair", "dining chair", "seating", "dining"], Size3(440, 500, 900)) { b in
                let hw = b.hw, hd = b.hd, o = Palette.oak
                for (xn, xr) in [("left", (-hw) ... (-hw + 36)), ("right", (hw - 36) ... hw)] {
                    b.add("Front leg \(xn)", x: xr, y: -hd ... (-hd + 36), z: 0 ... 420, o)
                    b.add("Back post \(xn)", x: xr, y: (hd - 36) ... hd, z: 0 ... 900, o)
                }
                b.add("Seat", .cushion, x: -hw ... hw, y: -hd ... hd, z: 420 ... 450, Palette.leather)
                b.add("Back panel", x: (-hw + 36) ... (hw - 36), y: (hd - 30) ... (hd - 10), z: 560 ... 860, o)
                b.add("Top rail", x: (-hw + 36) ... (hw - 36), y: (hd - 36) ... hd, z: 860 ... 900, o)
            },
        ]
    }

    // MARK: Decor

    private static func decor() -> [CatalogEntry] {
        [
            entry("rug.2000x3000", "Rug 200 x 300", "Decor", ["rug", "carpet", "floor"], Size3(2000, 3000, 10)) { b in
                b.add("Rug", .panel, x: -b.hw ... b.hw, y: -b.hd ... b.hd, z: 0 ... 10, Palette.rug)
            },
            entry("plant.floor", "Potted plant", "Decor", ["plant", "pot", "greenery"], Size3(450, 450, 1400)) { b in
                b.add("Pot", .cylinder, x: -150 ... 150, y: -150 ... 150, z: 0 ... 300, Palette.ceramic)
                b.add("Soil", .cylinder, x: -135 ... 135, y: -135 ... 135, z: 296 ... 304, Palette.soil)
                b.add("Stem", .cylinder, x: -15 ... 15, y: -15 ... 15, z: 304 ... 800, Palette.walnut)
                b.add("Foliage main", .sphere, x: -225 ... 225, y: -225 ... 225, z: 700 ... 1150, Palette.leaf)
                b.add("Foliage low", .sphere, x: -220 ... 60, y: -60 ... 220, z: 500 ... 800, Palette.leaf)
                b.add("Foliage top", .sphere, x: -120 ... 180, y: -200 ... 50, z: 950 ... 1400, Palette.leaf)
            },
        ]
    }

    // MARK: Lighting

    private static func lighting() -> [CatalogEntry] {
        [
            entry("lamp.floor", "Floor lamp", "Lighting", ["lamp", "floor lamp", "light", "lighting"], Size3(400, 400, 1600)) { b in
                b.add("Base", .cylinder, x: -150 ... 150, y: -150 ... 150, z: 0 ... 20, Palette.blackMetal)
                b.add("Pole", .cylinder, x: -15 ... 15, y: -15 ... 15, z: 20 ... 1400, Palette.blackMetal)
                b.add("Shade", .sphere, x: -180 ... 180, y: -180 ... 180, z: 1300 ... 1600, Palette.lampshade)
            },
            entry("lamp.table", "Table lamp", "Lighting", ["lamp", "table lamp", "light", "lighting"], Size3(300, 300, 450)) { b in
                b.add("Base", .cylinder, x: -70 ... 70, y: -70 ... 70, z: 0 ... 20, Palette.blackMetal)
                b.add("Body", .sphere, x: -80 ... 80, y: -80 ... 80, z: 20 ... 180, Palette.ceramic)
                b.add("Neck", .cylinder, x: -15 ... 15, y: -15 ... 15, z: 180 ... 300, Palette.blackMetal)
                b.add("Shade", .cylinder, x: -150 ... 150, y: -150 ... 150, z: 280 ... 450, Palette.lampshade)
            },
        ]
    }
}
