import Foundation
import Testing
@testable import RoomsmithCore

/// P01 core part: builds the stress project and measures the document-side costs. Prints one line per metric
/// ("BENCH name ms") so scripts/benchmark.sh can collect them into docs/PERFORMANCE.md. Upper bounds are generous
/// (debug build, any Mac) and only catch accidental quadratic behaviour.
@Suite("Benchmark", .serialized)
@MainActor
struct BenchmarkTests {
    private func ms(_ body: () throws -> Void) rethrows -> Double {
        let t0 = DispatchTime.now().uptimeNanoseconds
        try body()
        return Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
    }

    private func report(_ name: String, _ value: Double) {
        print("BENCH \(name) \(String(format: "%.2f", value))")
    }

    @Test func stressProject() throws {
        var p = Project.empty(name: "x")
        let tMake = try ms { p = try BenchmarkProject.make() }
        #expect(p.instances.count == 1000)
        #expect(p.walls.count >= 100)
        #expect(p.groups.count == 20)
        report("make_project", tMake)
        var everything = p
        let all = ChangeSet.diff(from: Project.empty(name: "x"), to: &everything, stamp: p.revision + 1)
        let tValidate = try ms { try Validator.validate(everything, changes: all) }
        report("validate_all", tValidate)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rs-bench-\(UUID().uuidString).roomsmith")
        defer { try? FileManager.default.removeItem(at: dir) }
        let tSave = try ms { try ProjectPackage.save(p, to: dir) }
        report("save_package", tSave)
        let size = (try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("project.md").path)[.size] as? Int) ?? 0
        report("project_md_kb", Double(size) / 1024)

        var loaded = p
        let tLoad = try ms { loaded = try ProjectPackage.load(from: dir).project }
        report("load_package", tLoad)
        #expect(loaded.instances.count == 1000)

        let level = p.levels[0].id
        let tOutline = ms { _ = WallOutline.compute(p.walls, levelId: level) }
        report("wall_outlines", tOutline)

        let tMesh = ms {
            let outlines = WallOutline.compute(p.walls, levelId: level)
            for w in p.walls {
                guard let o = outlines[w.id] else { continue }
                _ = Meshes.wall(w, outline: o, openings: p.openings.filter { $0.wallId == w.id }, baseZ: 0)
            }
        }
        report("wall_meshes_all", tMesh)

        let tCollideAll = ms { _ = CollisionChecker.check(p, levelId: level) }
        report("collision_all", tCollideAll)
        let one = p.instances[500].id
        let tCollideOne = ms { _ = CollisionChecker.check(p, levelId: level, only: [one]) }
        report("collision_one", tCollideOne)

        // Command latency: move one object through the store (diff + validate + undo record + event).
        let store = DocumentStore(project: p)
        var commandTimes: [Double] = []
        for i in 0..<20 {
            let t = try ms { try store.run("Move") { try $0.moveObjects([one], by: P3(i % 2 == 0 ? 10 : -10, 0, 0)) } }
            commandTimes.append(t)
        }
        commandTimes.sort()
        report("command_move_one_median", commandTimes[commandTimes.count / 2])
        report("command_move_one_max", commandTimes.last ?? 0)
        let tUndo = try ms { try store.undo() }
        report("undo_one", tUndo)

        let tSVG = ms { _ = PlanExport.svg(p, options: .init(levelId: level)) }
        report("export_svg", tSVG)
        var vcount = 0
        let tFurnMesh = ms {
            for inst in p.instances {
                var mesh = MeshData()
                for c in FurnitureResolver.resolve(inst, in: p, levelElevation: 0) where c.visible {
                    mesh.append(Meshes.unitPrimitive(c.shape, component: c.componentId).transformed(c.worldMatrix))
                }
                vcount += mesh.positions.count
            }
        }
        report("furniture_meshes_all", tFurnMesh)
        report("furniture_vertices", Double(vcount))
        let tOBJ = ms { _ = SceneExport.obj(p, levelId: level) }
        report("export_obj", tOBJ)

        #expect(commandTimes[commandTimes.count / 2] < 250)
        #expect(tLoad < 5000)
    }
}
