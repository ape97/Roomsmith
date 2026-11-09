import Foundation
import simd

/// One visible furniture component seen from above, in world plan millimetres.
public struct TopViewShape: Sendable, Equatable {
    public var componentId: UUID
    /// Outline, counter-clockwise: convex hull of the 3D mesh, identical to the 3D view (32-segment polygon, not the exact curve).
    public var points: [V2]
    /// Projected centre of the component.
    public var center: V2
    /// Material colour of the component (nil: no material).
    public var color: RGBColor?
    /// Highest and lowest world z (mm, level elevation included).
    public var topZ: Double
    public var bottomZ: Double
    public var area: Double
}

/// All visible components of one instance seen from above, sorted by top height (lowest first, so the drawing
/// order lets higher parts cover lower ones).
public struct FurnitureTopView: Sendable, Equatable {
    public var shapes: [TopViewShape]
    /// Colour that stands for the whole piece when only the outline is drawn: that of the largest high part.
    public var overallColor: RGBColor?

    /// Top view of an instance. Returns an empty list for an unknown definition.
    public static func shapes(_ inst: FurnitureInstance, in project: Project) -> FurnitureTopView {
        guard let def = project.definitions.first(where: { $0.id == inst.definitionId }) else { return FurnitureTopView(shapes: [], overallColor: nil) }
        let elev = project.levels.first(where: { $0.id == inst.levelId })?.elevation ?? 0
        var colors: [UUID: RGBColor] = [:]
        for m in project.materials { colors[m.id] = m.color }
        return make(inst, definition: def, colors: colors, levelElevation: elev)
    }

    public static func make(_ inst: FurnitureInstance, definition def: FurnitureDefinition, colors: [UUID: RGBColor],
                            levelElevation: MM = 0) -> FurnitureTopView {
        var out: [TopViewShape] = []
        for c in FurnitureResolver.resolve(inst, definition: def, levelElevation: levelElevation) where c.visible {
            let m = c.worldMatrix
            func world(_ x: Double, _ y: Double, _ z: Double) -> SIMD4<Double> { m * SIMD4(x, y, z, 1) }
            var zs: [Double] = []
            for ix in [-0.5, 0.5] { for iy in [-0.5, 0.5] { for iz in [-0.5, 0.5] { zs.append(world(ix, iy, iz).z) } } }
            let centre = world(0, 0, 0)
            // Silhouette = convex hull of the XY projection of the real 3D mesh, so top and 3D view always agree.
            // The projection is affine, so hulling the (deduplicated, cached) unit-mesh points mapped by the matrix is exact.
            let pts = convexHull(unitPoints[c.shape, default: []].map { let q = m * SIMD4($0.x, $0.y, $0.z, 1); return V2(q.x, q.y) })
            guard pts.count >= 3 else { continue }
            out.append(TopViewShape(componentId: c.componentId, points: pts, center: V2(centre.x, centre.y),
                                    color: c.materialId.flatMap { colors[$0] }, topZ: zs.max() ?? 0, bottomZ: zs.min() ?? 0,
                                    area: polygonArea(pts)))
        }
        // Stable: equal heights keep the component order.
        let sorted = out.enumerated().sorted { a, b in
            a.element.topZ != b.element.topZ ? a.element.topZ < b.element.topZ : a.offset < b.offset
        }.map(\.element)
        // Representative colour: among parts reaching the top, the one with the largest area.
        let overall: RGBColor? = {
            guard let top = sorted.last?.topZ else { return nil }
            let high = sorted.filter { $0.topZ >= top - 0.35 * max(top - (sorted.first?.bottomZ ?? 0), 1) }
            return (high.max { $0.area < $1.area } ?? sorted.last)?.color
        }()
        return FurnitureTopView(shapes: sorted, overallColor: overall)
    }

    /// Unique vertices of each unit primitive mesh (the mesh duplicates vertices per face); computed once.
    private static let unitPoints: [PrimitiveShape: [SIMD3<Double>]] = {
        var out: [PrimitiveShape: [SIMD3<Double>]] = [:]
        for shape in PrimitiveShape.allCases {
            var seen = Set<[Int64]>(); var pts: [SIMD3<Double>] = []
            for q in Meshes.unitPrimitive(shape).positions {
                let key = [Int64((q.x * 1e6).rounded()), Int64((q.y * 1e6).rounded()), Int64((q.z * 1e6).rounded())]
                if seen.insert(key).inserted { pts.append(q) }
            }
            out[shape] = pts
        }
        return out
    }()

    /// Convex hull, counter-clockwise, without collinear points (Andrew's monotone chain).
    static func convexHull(_ pts: [V2]) -> [V2] {
        let p = pts.sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
        guard p.count > 2 else { return p }
        func cross(_ o: V2, _ a: V2, _ b: V2) -> Double { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
        let eps = 1e-6
        var lower: [V2] = []
        for q in p { while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], q) <= eps { lower.removeLast() }; lower.append(q) }
        var upper: [V2] = []
        for q in p.reversed() { while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], q) <= eps { upper.removeLast() }; upper.append(q) }
        lower.removeLast(); upper.removeLast()
        return lower + upper
    }

    static func polygonArea(_ p: [V2]) -> Double {
        var a = 0.0
        for i in p.indices { let q = p[(i + 1) % p.count]; a += p[i].x * q.y - q.x * p[i].y }
        return abs(a) / 2
    }
}

/// Thread-safe cache of top views per instance value. An entry is reused only while the definition and the
/// material colours are unchanged, so edits can never show stale shapes.
public final class FurnitureTopViewCache: @unchecked Sendable {
    private struct Entry { var definition: FurnitureDefinition; var signature: Int; var elevation: MM; var view: FurnitureTopView }
    private var entries: [FurnitureInstance: Entry] = [:]
    private let lock = NSLock()
    public init() {}

    public static func signature(of materials: [Material]) -> Int {
        var h = Hasher()
        for m in materials { h.combine(m.id); h.combine(m.color) }
        return h.finalize()
    }

    public func view(_ inst: FurnitureInstance, definition def: FurnitureDefinition, colors: [UUID: RGBColor],
                     signature: Int, levelElevation: MM) -> FurnitureTopView {
        lock.lock()
        if let e = entries[inst], e.signature == signature, e.elevation == levelElevation, e.definition == def {
            lock.unlock(); return e.view
        }
        lock.unlock()
        let v = FurnitureTopView.make(inst, definition: def, colors: colors, levelElevation: levelElevation)
        lock.lock()
        if entries.count > 6000 { entries.removeAll(keepingCapacity: true) }
        entries[inst] = Entry(definition: def, signature: signature, elevation: levelElevation, view: v)
        lock.unlock()
        return v
    }
}
