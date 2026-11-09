import Foundation
import Testing
import simd
@testable import RoomsmithCore

private struct Box {
    var lo = SIMD3<Double>(repeating: .infinity)
    var hi = SIMD3<Double>(repeating: -.infinity)
    mutating func add(_ p: SIMD3<Double>) { lo = simd_min(lo, p); hi = simd_max(hi, p) }
}

private func worldBox(_ c: ResolvedComponent) -> Box {
    var b = Box()
    for x in [-0.5, 0.5] { for y in [-0.5, 0.5] { for z in [-0.5, 0.5] {
        let v = c.worldMatrix * SIMD4<Double>(x, y, z, 1)
        b.add(SIMD3(v.x, v.y, v.z))
    } } }
    return b
}

private func resolved(_ key: String, state: String?) -> [ResolvedComponent] {
    let def = BuiltinCatalog.definition(key)!
    var inst = FurnitureInstance(definitionId: def.id, levelId: UUID(), name: key, position: .zero)
    if let state { inst.stateId = def.states.first { $0.name == state }?.id }
    return FurnitureResolver.resolve(inst, definition: def)
}

@Suite struct CatalogTests {
    let all = BuiltinCatalog.entries

    @Test func countAndCategories() {
        #expect(all.count >= 30)
        let cats = Set(all.map(\.category))
        for c in ["Living", "Bedroom", "Kitchen", "Bathroom", "Office", "Dining", "Decor", "Lighting"] { #expect(cats.contains(c), "\(c)") }
    }

    @Test func keysUniqueAndDefinitionsDeterministic() {
        #expect(Set(all.map(\.key)).count == all.count)
        for e in all {
            let a = BuiltinCatalog.definition(e.key)!, b = BuiltinCatalog.definition(e.key)!
            #expect(a == b, "\(e.key)")
            #expect(a.builtin && a.catalogKey == e.key)
        }
        #expect(BuiltinCatalog.definition("does.not.exist") == nil)
    }

    @Test func sizesAndComponentsInsideBoundingBox() {
        for e in all {
            let d = BuiltinCatalog.definition(e.key)!
            #expect(d.size.isValid, "\(e.key)")
            #expect(!d.components.isEmpty)
            var minZ = Int64.max
            for c in d.components {
                #expect(c.size.isValid, "\(e.key)/\(c.name)")
                #expect(abs(c.position.x) + c.size.width / 2 <= d.size.width / 2 + 1, "\(e.key)/\(c.name) x")
                #expect(abs(c.position.y) + c.size.depth / 2 <= d.size.depth / 2 + 1, "\(e.key)/\(c.name) y")
                #expect(c.position.z - c.size.height / 2 >= -1 && c.position.z + c.size.height / 2 <= d.size.height + 1, "\(e.key)/\(c.name) z")
                minZ = min(minZ, c.position.z - c.size.height / 2)
            }
            #expect(abs(minZ) <= 1, "\(e.key) floor contact \(minZ)")
        }
    }

    @Test func statesAndTracksConsistent() {
        for e in all {
            let d = BuiltinCatalog.definition(e.key)!
            let comps = Set(d.components.map(\.id)), states = Set(d.states.map(\.id))
            for s in d.states { for id in s.poses.keys { #expect(comps.contains(id), "\(e.key) pose") } }
            if !d.states.isEmpty { #expect(d.defaultStateId.map(states.contains) == true, "\(e.key) default") }
            for t in d.tracks {
                #expect(states.contains(t.toStateId))
                if let f = t.fromStateId { #expect(states.contains(f)) }
                for k in t.keyframes { for id in k.poses.keys { #expect(comps.contains(id)) } }
            }
        }
    }

    @Test func wallBed() throws {
        let d = try #require(BuiltinCatalog.definition("bed.wall.1400"))
        let folded = try #require(d.states.first { $0.name == "folded" })
        let unfolded = try #require(d.states.first { $0.name == "unfolded" })
        #expect(d.defaultStateId == folded.id)
        #expect(folded.size != nil && unfolded.size != nil)
        let t = try #require(d.tracks.first { $0.fromStateId == folded.id && $0.toStateId == unfolded.id })
        #expect(t.durationMs == 1200)
        let mattressId = try #require(d.components.first { $0.name == "Mattress" }?.id)
        #expect(unfolded.poses[mattressId]?.rotation == R3(90, 0, 0))
        let bf = worldBox(try #require(resolved("bed.wall.1400", state: "folded").first { $0.name == "Mattress" }))
        #expect(bf.hi.z - bf.lo.z > bf.hi.y - bf.lo.y)
        let bu = worldBox(try #require(resolved("bed.wall.1400", state: "unfolded").first { $0.name == "Mattress" }))
        #expect(bu.hi.z <= 600.5, "top \(bu.hi.z)")
        #expect(bu.hi.y - bu.lo.y > 1900)
    }

    @Test func drawerAndDoorStates() throws {
        let d = try #require(BuiltinCatalog.definition("dresser.4drawer.900"))
        let open = try #require(d.states.first { $0.name == "open" })
        let front = try #require(d.components.first { $0.name == "Drawer 4 front" })
        #expect(open.poses[front.id]?.position?.y == front.position.y - 400)
        let w = try #require(BuiltinCatalog.definition("wardrobe.1000"))
        let o = try #require(w.states.first { $0.name == "open" })
        #expect(o.poses.values.contains { abs(abs($0.rotation?.z ?? 0) - 100) < 0.001 })
        let rug = try #require(BuiltinCatalog.definition("rug.2000x3000"))
        #expect(rug.size.height == 10)
    }

    @Test func modularSofaConfigurations() throws {
        var p = Project(name: "t")
        let level = Level(name: "L0"); p.levels.append(level)
        let gid = try BuiltinCatalog.insertModularSofa(into: &p, levelId: level.id, origin: P2(0, 0))
        let g = try #require(p.groups.first { $0.id == gid })
        #expect(g.configurations.count == 3)
        #expect(Set(g.configurations.map(\.name)) == ["L-shape", "Straight", "U-shape"])
        #expect(Set(g.memberIds).count == 7)
        for cfg in g.configurations {
            var rects: [OrientedRect] = []
            for id in g.memberIds {
                guard let pose = cfg.poses[id], pose.visible, var inst = p.instances.first(where: { $0.id == id }) else { continue }
                inst.position = P3(g.origin.x + pose.local.x, g.origin.y + pose.local.y, 0)
                inst.rotationDeg = pose.rotationDeg
                let def = try #require(p.definitions.first { $0.id == inst.definitionId })
                rects.append(FurnitureResolver.footprint(of: inst, definition: def))
            }
            #expect(rects.count >= 4, "\(cfg.name)")
            for i in rects.indices {
                var touching = false
                for j in rects.indices where i != j {
                    #expect(!rects[i].overlaps(rects[j], margin: 1), "\(cfg.name) overlap \(i)/\(j)")
                    if rects[i].overlaps(rects[j], margin: -1) { touching = true }
                }
                #expect(touching, "\(cfg.name) module \(i) has no contact")
            }
        }
    }

    @Test func parametricBuilder() {
        let s = Size3(1200, 500, 900)
        let defs = [
            ParametricBuilder.cabinet(name: "c", size: s, shelves: 2, doors: 2, plinth: 80, materialId: nil),
            ParametricBuilder.table(name: "t", size: s, legInset: 50, topThickness: 30, materialId: nil),
            ParametricBuilder.shelf(name: "s", size: s, boards: 4, materialId: nil),
            ParametricBuilder.sofa(name: "so", size: Size3(2000, 900, 850), armWidth: 150, seatHeight: 430, materialId: nil),
            ParametricBuilder.box(name: "b", size: s, materialId: nil),
        ]
        for d in defs {
            #expect(d.size.isValid && !d.components.isEmpty)
            let ids = Set(d.components.map(\.id))
            #expect(ids.count == d.components.count)
            for c in d.components {
                #expect(abs(c.position.x) + c.size.width / 2 <= d.size.width / 2 + 1)
                #expect(abs(c.position.y) + c.size.depth / 2 <= d.size.depth / 2 + 1)
                #expect(c.position.z - c.size.height / 2 >= -1 && c.position.z + c.size.height / 2 <= d.size.height + 1)
            }
        }
    }

    @Test func search() {
        #expect(!BuiltinCatalog.search("sofa").isEmpty)
        #expect(BuiltinCatalog.search("").count == all.count)
        #expect(BuiltinCatalog.search("zzzzqq").isEmpty)
        #expect(!BuiltinCatalog.materials.isEmpty)
    }

    // MARK: Review fixes

    @Test func makeReturnsCompleteDefinitions() {
        let ids = Set(BuiltinCatalog.materials.map(\.id))
        for e in all {
            let d = e.make()
            #expect(d.name == e.name && d.category == e.category && d.tags == e.tags, "\(e.key)")
            #expect(d.builtin && d.catalogKey == e.key, "\(e.key)")
            #expect(d == BuiltinCatalog.definition(e.key), "\(e.key)")
            do { try Validator.validateDefinition(d, materialIds: ids) } catch { Issue.record("\(e.key): \(error)") }
        }
    }

    @Test func noStatePoseSinksBelowTheFloor() {
        for e in all {
            let d = BuiltinCatalog.definition(e.key)!
            for st in d.states {
                var inst = FurnitureInstance(definitionId: d.id, levelId: UUID(), name: e.key, position: .zero)
                inst.stateId = st.id
                for c in FurnitureResolver.resolve(inst, definition: d) where c.visible {
                    #expect(worldBox(c).lo.z >= -1, "\(e.key)/\(st.name)/\(c.name) z \(worldBox(c).lo.z)")
                }
            }
        }
    }

    @Test func fridgeFreezerDoorOpens() throws {
        let d = try #require(BuiltinCatalog.definition("fridge.600"))
        let open = try #require(d.states.first { $0.name == "open" })
        for name in ["Fridge door", "Fridge handle", "Freezer door", "Freezer handle"] {
            let id = try #require(d.components.first { $0.name == name }?.id, Comment(rawValue: name))
            #expect(open.poses[id]?.rotation == R3(0, 0, -100), Comment(rawValue: name))
        }
        let closed = worldBox(try #require(resolved("fridge.600", state: "closed").first { $0.name == "Freezer door" }))
        let opened = worldBox(try #require(resolved("fridge.600", state: "open").first { $0.name == "Freezer door" }))
        #expect(opened.lo.y < closed.lo.y - 300)
    }

    @Test func footprintWithoutStateStaysCentred() throws {
        let d = try #require(BuiltinCatalog.definition("table.coffee.1000"))
        var inst = FurnitureInstance(definitionId: d.id, levelId: UUID(), name: "t", position: P3(1000, 2000, 0), rotationDeg: 30)
        let r = FurnitureResolver.footprint(of: inst, definition: d)
        #expect(r.center == V2(1000, 2000))
        #expect(r.halfSize == V2(Double(d.size.width) / 2, Double(d.size.depth) / 2))
        // a state that moves nothing keeps the centred size rectangle as well
        let w = try #require(BuiltinCatalog.definition("wardrobe.1000"))
        inst = FurnitureInstance(definitionId: w.id, levelId: UUID(), name: "w", position: P3(0, 0, 0))
        inst.stateId = w.states.first { $0.name == "closed" }?.id
        #expect(FurnitureResolver.footprint(of: inst, definition: w).center == V2(0, 0))
    }

    @Test func unfoldedWallBedGrowsForwardNotThroughTheWall() throws {
        let d = try #require(BuiltinCatalog.definition("bed.wall.1400"))
        var inst = FurnitureInstance(definitionId: d.id, levelId: UUID(), name: "b", position: P3(3000, 1000, 0))
        inst.stateId = d.states.first { $0.name == "folded" }?.id
        let folded = FurnitureResolver.footprint(of: inst, definition: d).bounds
        inst.stateId = d.states.first { $0.name == "unfolded" }?.id
        let rect = FurnitureResolver.footprint(of: inst, definition: d)
        let b = rect.bounds
        #expect(abs(b.max.y - folded.max.y) <= 1, "back edge stays at the wall: \(b.max.y) vs \(folded.max.y)")
        #expect(b.min.y <= 1000 - 225 - 1999, "reaches the mattress end \(b.min.y)")
        #expect(abs(b.max.x - b.min.x - 1500) <= 1)
        let mattress = try #require(FurnitureResolver.resolve(inst, definition: d).first { $0.name == "Mattress" })
        let mb = worldBox(mattress)
        for x in [mb.lo.x, mb.hi.x] { for y in [mb.lo.y, mb.hi.y] { #expect(rect.contains(V2(x, y))) } }
    }

    @Test func openDresserDrawerExtendsTheFootprintForwardOnly() throws {
        let d = try #require(BuiltinCatalog.definition("dresser.4drawer.900"))
        var inst = FurnitureInstance(definitionId: d.id, levelId: UUID(), name: "d", position: P3(0, 0, 0))
        inst.stateId = d.states.first { $0.name == "closed" }?.id
        let closed = FurnitureResolver.footprint(of: inst, definition: d).bounds
        inst.stateId = d.states.first { $0.name == "open" }?.id
        let open = FurnitureResolver.footprint(of: inst, definition: d).bounds
        #expect(abs(open.max.y - closed.max.y) <= 1)
        #expect(abs((closed.min.y - open.min.y) - 400) <= 1, "grows by the drawer travel: \(closed.min.y - open.min.y)")
    }

    @Test func footprintContainsEveryVisibleComponentInEveryState() {
        for e in all {
            let d = BuiltinCatalog.definition(e.key)!
            for st in d.states {
                var inst = FurnitureInstance(definitionId: d.id, levelId: UUID(), name: e.key, position: P3(500, -300, 0), rotationDeg: 37)
                inst.stateId = st.id
                let r = FurnitureResolver.footprint(of: inst, definition: d)
                let grown = OrientedRect(center: r.center, halfSize: r.halfSize + V2(repeating: 1), rotationDeg: r.rotationDeg)
                for c in FurnitureResolver.resolve(inst, definition: d) where c.visible && !st.poses.isEmpty {
                    // the oriented component corners (not the loose AABB) must lie inside
                    for ix in [-0.5, 0.5] { for iy in [-0.5, 0.5] {
                        let v = c.worldMatrix * SIMD4<Double>(ix, iy, 0, 1)
                        #expect(grown.contains(V2(v.x, v.y)), "\(e.key)/\(st.name)/\(c.name)")
                    } }
                }
            }
        }
    }

    @Test func snapDocksTheUnfoldedWallBedWithItsBackEdge() throws {
        let d = try #require(BuiltinCatalog.definition("bed.wall.1400"))
        var inst = FurnitureInstance(definitionId: d.id, levelId: UUID(), name: "b", position: P3(2000, 2700, 0))
        inst.stateId = d.states.first { $0.name == "unfolded" }?.id
        let wall = Wall(levelId: inst.levelId, start: P2(0, 3000), end: P2(4000, 3000), thickness: 100)
        let ctx = SnapContext(walls: [wall])
        let r = SnapEngine.snapFurniture(inst, definition: d, proposed: P2(2000, 2700), context: ctx, tolerance: 100, alignRotation: false)
        #expect(r.kind == .wallFace)
        inst.position = P3(r.position.x, r.position.y, 0)
        #expect(abs(FurnitureResolver.footprint(of: inst, definition: d).bounds.max.y - 2950) <= 1)
    }

    @Test func parametricSizesAreNotRaisedAndIdsDoNotCollide() {
        let tiny = ParametricBuilder.box(name: "x", size: Size3(40, 60, 1), materialId: nil)
        #expect(tiny.size == Size3(40, 60, 1))
        #expect(ParametricBuilder.box(name: "x", size: Size3(0, -5, 200_000), materialId: nil).size == Size3(1, 1, 100_000))
        let a = ParametricBuilder.cabinet(name: "same", size: Size3(800, 400, 900), shelves: 1, doors: 1, plinth: 60, materialId: nil)
        let b = ParametricBuilder.cabinet(name: "same", size: Size3(900, 400, 900), shelves: 1, doors: 1, plinth: 60, materialId: nil)
        #expect(a.id != b.id)
        // component ids are only stable for the same name and template (key `param.<kind>.<name>`); a rename or template
        // change gives new ids and `updateDefinition` discards the overrides that no longer match
        #expect(a.components.map(\.id) == b.components.map(\.id))
    }

    private func generatedDefinitions(_ w: MM, _ d: MM, _ h: MM) -> [FurnitureDefinition] {
        let s = Size3(w, d, h)
        return [
            ParametricBuilder.box(name: "t", size: s, materialId: nil),
            ParametricBuilder.cabinet(name: "t", size: s, shelves: 3, doors: 2, plinth: 60, materialId: nil),
            ParametricBuilder.cabinet(name: "t", size: s, shelves: 0, doors: 0, plinth: 0, materialId: nil),
            ParametricBuilder.table(name: "t", size: s, legInset: 30, topThickness: 30, materialId: nil),
            ParametricBuilder.shelf(name: "t", size: s, boards: 1, materialId: nil),
            ParametricBuilder.shelf(name: "t", size: s, boards: 5, materialId: nil),
            ParametricBuilder.sofa(name: "t", size: s, armWidth: 150, seatHeight: 450, materialId: nil),
            ParametricBuilder.sofa(name: "t", size: s, armWidth: 0, seatHeight: 450, materialId: nil),
        ]
    }

    @Test func generatorsSurviveTinySizesAndStayInsideTheEnvelope() {
        let axis: [MM] = [1, 2, 5, 20, 100, 220, 2000]
        for w in axis { for d in axis { for h in axis {
            for def in generatedDefinitions(w, d, h) {
                #expect(def.size == Size3(w, d, h))
                #expect(!def.components.isEmpty)
                for c in def.components {
                    let tag = "\(def.name) \(c.name) in \(w)x\(d)x\(h)"
                    // half a millimetre of slack: centres are whole millimetres, so odd extents sit on .5
                    #expect(Double(abs(c.position.x)) + Double(c.size.width) / 2 <= Double(w) / 2 + 0.5, "x \(tag)")
                    #expect(Double(abs(c.position.y)) + Double(c.size.depth) / 2 <= Double(d) / 2 + 0.5, "y \(tag)")
                    #expect(Double(c.position.z) - Double(c.size.height) / 2 >= -0.5, "z0 \(tag)")
                    #expect(Double(c.position.z) + Double(c.size.height) / 2 <= Double(h) + 0.5, "z1 \(tag)")
                    #expect(c.size.width >= 1 && c.size.depth >= 1 && c.size.height >= 1, Comment(rawValue: tag))
                }
            }
        } } }
    }

    @Test func generatorsSurviveReportedCrashSizes() {
        #expect(!generatedDefinitions(2000, 900, 150).isEmpty)
        for h: MM in [150, 170, 200, 220, 221, 400] { #expect(!generatedDefinitions(2000, 900, h).isEmpty) }
    }

    @Test func scaledInstanceWithPosesScalesTheFootprint() throws {
        let d = try #require(BuiltinCatalog.definition("bed.wall.1400"))
        let unfolded = try #require(d.states.first { $0.name == "unfolded" })
        var inst = FurnitureInstance(definitionId: d.id, levelId: UUID(), name: "bed", position: .zero)
        inst.stateId = unfolded.id
        let one = FurnitureResolver.localFootprint(of: inst, definition: d)
        inst.size = Size3(d.size.width * 2, d.size.depth * 2, d.size.height * 2)
        let two = FurnitureResolver.localFootprint(of: inst, definition: d)
        #expect(one.half.x > 0 && one.half.y > 0)
        #expect(abs(two.half.x - 2 * one.half.x) < 1e-6)
        #expect(abs(two.half.y - 2 * one.half.y) < 1e-6)
        #expect(abs(two.center.x - 2 * one.center.x) < 1e-6)
        #expect(abs(two.center.y - 2 * one.center.y) < 1e-6)
        let rect1 = FurnitureResolver.footprint(of: { var i = inst; i.size = nil; return i }(), definition: d)
        let rect2 = FurnitureResolver.footprint(of: inst, definition: d)
        #expect(abs(rect2.halfSize.x - 2 * rect1.halfSize.x) < 1e-6)
        #expect(abs(rect2.halfSize.y - 2 * rect1.halfSize.y) < 1e-6)
    }

    @Test func footprintFallsBackToTheSizeRectWhenNothingIsVisible() throws {
        var d = try #require(BuiltinCatalog.definition("bed.wall.1400"))
        let hidden = FurnitureState(name: "hidden", poses: Dictionary(uniqueKeysWithValues: d.components.map {
            ($0.id, ComponentPose(position: nil, rotation: nil, size: nil, visible: false))
        }))
        d.states.append(hidden)
        var inst = FurnitureInstance(definitionId: d.id, levelId: UUID(), name: "bed", position: .zero)
        inst.stateId = hidden.id
        var fp = FurnitureResolver.localFootprint(of: inst, definition: d)
        #expect(fp.center == .zero)
        #expect(fp.half.x == Double(d.size.width) / 2 && fp.half.y == Double(d.size.depth) / 2)
        inst.size = Size3(d.size.width * 2, d.size.depth * 2, d.size.height)
        fp = FurnitureResolver.localFootprint(of: inst, definition: d)
        #expect(fp.half.x == Double(d.size.width) && fp.half.y == Double(d.size.depth))
    }
}
