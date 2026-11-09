import Foundation
import simd

/// Wavefront OBJ/MTL export of the 3D scene. Y up, metres: world (x, y, z) mm becomes (x, z, -y) / 1000.
///
/// Materials are simplified to what MTL can say: base colour (`Kd`), opacity (`d`), roughness as shininess (`Ns`),
/// metallic as the PBR extension `Pm` plus a rough specular colour `Ks` (dielectric 0.04, towards the base colour with
/// metallic). Textures, procedural patterns, clearcoat and finish are not exported; only the flat colour travels.
public enum SceneExport {
    private struct MaterialSpec {
        var name: String; var color: RGBColor; var opacity: Double; var roughness: Double
        var metallic: Double = 0
    }

    private struct Writer {
        var obj = ""
        var vertexBase = 1
        var materials: [MaterialSpec] = []
        var used: Set<String> = []

        /// Six decimals, trailing zeros removed, no "-0". Integer arithmetic instead of `String(format:)`:
        /// a 1,000-piece scene writes millions of numbers, and the formatter dominated the export time.
        static func num(_ v: Double) -> String {
            let scaled = (v * 1_000_000).rounded(.toNearestOrAwayFromZero)
            guard scaled.isFinite, abs(scaled) < 9e15 else { return v.isFinite ? String(v) : "0" }
            var n = Int64(scaled)
            if n == 0 { return "0" }
            let negative = n < 0
            if negative { n = -n }
            var s = negative ? "-" : ""
            s += String(n / 1_000_000)
            var frac = n % 1_000_000
            if frac != 0 {
                var digits = 6
                while frac % 10 == 0 { frac /= 10; digits -= 1 }
                let f = String(frac)
                s += "."
                if f.count < digits { s += String(repeating: "0", count: digits - f.count) }
                s += f
            }
            return s
        }

        mutating func register(_ spec: MaterialSpec) -> String {
            if used.insert(spec.name).inserted { materials.append(spec) }
            return spec.name
        }

        mutating func object(_ name: String, _ mesh: MeshData, material: (MeshRole) -> MaterialSpec) {
            guard !mesh.isEmpty else { return }
            obj += "o \(name)\n"
            for p in mesh.positions { obj += "v \(Self.num(p.x / 1000)) \(Self.num(p.z / 1000)) \(Self.num(-p.y / 1000))\n" }
            for n in mesh.normals { obj += "vn \(Self.num(n.x)) \(Self.num(n.z)) \(Self.num(-n.y))\n" }
            for t in mesh.uvs { obj += "vt \(Self.num(t.x / 1000)) \(Self.num(t.y / 1000))\n" }
            for part in mesh.parts {
                obj += "usemtl \(register(material(part.role)))\n"
                var i = part.indexRange.lowerBound
                while i + 2 < part.indexRange.upperBound {
                    var line = "f"
                    for k in 0..<3 {
                        let v = String(Int(mesh.indices[i + k]) + vertexBase)
                        line += " "; line += v; line += "/"; line += v; line += "/"; line += v
                    }
                    line += "\n"
                    obj += line
                    i += 3
                }
            }
            vertexBase += mesh.positions.count
        }
    }

    private static func sanitize(_ s: String, fallback: String) -> String {
        var r = ""
        for ch in s.unicodeScalars { r.append(CharacterSet.alphanumerics.contains(ch) ? Character(ch) : "_") }
        r = r.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return r.isEmpty ? fallback : r
    }

    /// Exports visible levels (or exactly `levelId` when given): walls, opening frames, room floors/ceilings, visible furniture.
    public static func obj(_ p: Project, levelId: UUID? = nil) -> (obj: String, mtl: String) {
        var w = Writer()
        w.obj = "# Roomsmith export, Y up, metres\nmtllib scene.mtl\n"
        let byId = Dictionary(p.materials.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let fallback = MaterialSpec(name: "default", color: RGBColor(204, 204, 204), opacity: 1, roughness: 0.8)
        let glass = MaterialSpec(name: "glass", color: RGBColor(170, 200, 230), opacity: 0.3, roughness: 0.1)
        let frosted = MaterialSpec(name: "glass_frosted", color: RGBColor(225, 232, 238), opacity: 0.75, roughness: 0.7)
        let tinted = MaterialSpec(name: "glass_tinted", color: RGBColor(70, 85, 95), opacity: 0.5, roughness: 0.1)
        let hardware = MaterialSpec(name: "hardware", color: RGBColor(176, 178, 182), opacity: 1, roughness: 0.3)
        // Door and window frames without a material: painted joinery, as in the 3D view (SceneMaterials `.frameDefault`).
        let frame = MaterialSpec(name: "frame", color: RGBColor(240, 237, 230), opacity: 1, roughness: 0.35)

        func spec(_ id: UUID?) -> MaterialSpec {
            guard let id, let m = byId[id] else { return fallback }
            return MaterialSpec(name: "\(sanitize(m.name, fallback: "material"))_\(id.uuidString.prefix(8))",
                                color: m.color, opacity: m.opacity, roughness: m.roughness, metallic: m.metallic)
        }

        let levels = p.levels.filter { levelId == nil ? $0.visible : $0.id == levelId }
        for level in levels {
            let walls = p.walls.filter { $0.levelId == level.id }
            let outlines = WallOutline.compute(walls, levelId: level.id)
            for (i, wall) in walls.enumerated() {
                guard let ol = outlines[wall.id] else { continue }
                let ops = p.openings.filter { $0.wallId == wall.id }
                let mesh = Meshes.wall(wall, outline: ol, openings: ops, baseZ: level.elevation)
                w.object("Wall_\(i + 1)", mesh) { role in
                    switch role {
                    case .wallLeft: spec(wall.leftMaterialId)
                    case .wallRight: spec(wall.rightMaterialId)
                    default: fallback
                    }
                }
                for (j, op) in ops.enumerated() {
                    let fm = Meshes.openingFrame(op, wall: wall, baseZ: level.elevation)
                    let name = "\(op.kind.rawValue.capitalized)_\(sanitize(op.name, fallback: "\(i + 1)_\(j + 1)"))"
                    w.object(name, fm) { role in
                        switch role {
                        case .glass: glass
                        case .glassFrosted: frosted
                        case .glassTinted: tinted
                        case .hardware: hardware
                        default: op.frameMaterialId.flatMap { byId[$0] } == nil ? frame : spec(op.frameMaterialId)
                        }
                    }
                }
            }
            for (i, room) in p.rooms.enumerated() where room.levelId == level.id {
                let label = sanitize(room.name, fallback: "\(i + 1)")
                if room.showFloor {
                    w.object("Floor_\(label)", Meshes.roomFloor(room, z: level.elevation)) { _ in spec(room.floorMaterialId) }
                }
                if room.showCeiling {
                    w.object("Ceiling_\(label)", Meshes.roomCeiling(room, z: level.elevation + level.height)) { _ in spec(room.ceilingMaterialId) }
                }
            }
            for (i, inst) in p.instances.enumerated() where inst.levelId == level.id && inst.visible {
                var mesh = MeshData()
                var matOf: [UUID: UUID?] = [:]
                for c in FurnitureResolver.resolve(inst, in: p, levelElevation: level.elevation) where c.visible {
                    mesh.append(Meshes.unitPrimitive(c.shape, component: c.componentId, size: c.size).transformed(c.worldMatrix))
                    matOf[c.componentId] = .some(c.materialId)
                }
                w.object("Furniture_\(sanitize(inst.name, fallback: "\(i + 1)"))", mesh) { role in
                    if case let .component(id) = role, let m = matOf[id] { return spec(m) }
                    return fallback
                }
            }
        }

        var mtl = "# Roomsmith materials\n"
        for m in w.materials {
            mtl += "newmtl \(m.name)\n"
            mtl += "Kd \(Writer.num(Double(m.color.r) / 255)) \(Writer.num(Double(m.color.g) / 255)) \(Writer.num(Double(m.color.b) / 255))\n"
            mtl += "d \(Writer.num(m.opacity))\n"
            mtl += "Ns \(Writer.num(((1 - m.roughness) * 1000).rounded()))\n"
            let metal = min(max(m.metallic, 0), 1)
            func ks(_ channel: UInt8) -> String { Writer.num(0.04 + metal * (Double(channel) / 255 - 0.04)) }
            mtl += "Ks \(ks(m.color.r)) \(ks(m.color.g)) \(ks(m.color.b))\n"
            mtl += "Pm \(Writer.num(metal))\n"
            mtl += "illum 2\n\n"
        }
        return (w.obj, mtl)
    }
}
