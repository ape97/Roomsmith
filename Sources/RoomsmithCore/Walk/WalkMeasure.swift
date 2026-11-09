import Foundation
import simd

/// A measurement the walk mode answers (also through `walk.measure`). All values in millimetres.
public struct WalkMeasurement: Sendable, Equatable {
    public var kind: String
    public var valueMm: Double
    public var detail: String
    public init(kind: String, valueMm: Double, detail: String) { self.kind = kind; self.valueMm = valueMm; self.detail = detail }
}

public enum WalkMeasureError: Error, Equatable, Sendable {
    case notFound(String)
    case invalid(String)
}

public enum WalkMeasure {
    public static let kinds = ["eye_above_surface", "window_sill", "door_clear", "gap"]

    /// Eye height minus the top of a furniture piece (positive: the eye is above it). Top = elevation + height.
    public static func eyeAboveSurface(eyeHeightMm: Double, project: Project, furnitureId: UUID) throws -> WalkMeasurement {
        guard let inst = project.instances.first(where: { $0.id == furnitureId }),
              let def = project.definitions.first(where: { $0.id == inst.definitionId }) else {
            throw WalkMeasureError.notFound("Furniture \(furnitureId)")
        }
        let top = Double(inst.position.z) + Double(FurnitureResolver.size(of: inst, definition: def).height)
        return WalkMeasurement(kind: "eye_above_surface", valueMm: eyeHeightMm - top,
                               detail: "Eye \(Int(eyeHeightMm.rounded())) mm, surface top \(Int(top.rounded())) mm")
    }

    /// Height of the window sill (parapet) above the floor.
    public static func windowSill(project: Project, openingId: UUID) throws -> WalkMeasurement {
        guard let o = project.openings.first(where: { $0.id == openingId }) else { throw WalkMeasureError.notFound("Opening \(openingId)") }
        guard o.kind == .window else { throw WalkMeasureError.invalid("Opening \(openingId) is not a window") }
        return WalkMeasurement(kind: "window_sill", valueMm: Double(o.sill), detail: "Sill height above the floor")
    }

    /// Clear width (valueMm) and clear height of a door or opening inside its frame.
    public static func doorClear(project: Project, openingId: UUID) throws -> (width: WalkMeasurement, height: Double) {
        guard let o = project.openings.first(where: { $0.id == openingId }) else { throw WalkMeasureError.notFound("Opening \(openingId)") }
        guard o.kind != .window else { throw WalkMeasureError.invalid("Opening \(openingId) is a window") }
        let ft = o.kind == .door ? Meshes.frameThickness(for: o) : 0
        let w = Double(o.width) - 2 * ft, h = Double(o.height) - ft
        return (WalkMeasurement(kind: "door_clear", valueMm: w, detail: "Clear width \(Int(w.rounded())) mm, clear height \(Int(h.rounded())) mm"), h)
    }

    /// Shortest distance between the footprints of two furniture pieces (0 when they overlap or touch).
    public static func gap(project: Project, a: UUID, b: UUID) throws -> WalkMeasurement {
        func rect(_ id: UUID) throws -> OrientedRect {
            guard let inst = project.instances.first(where: { $0.id == id }),
                  let def = project.definitions.first(where: { $0.id == inst.definitionId }) else {
                throw WalkMeasureError.notFound("Furniture \(id)")
            }
            return FurnitureResolver.footprint(of: inst, definition: def)
        }
        let ra = try rect(a), rb = try rect(b)
        let d = polygonDistance(ra.corners, rb.corners)
        return WalkMeasurement(kind: "gap", valueMm: d, detail: "Shortest distance between the two footprints")
    }

    /// Shortest distance between two convex polygons (0 if they intersect).
    public static func polygonDistance(_ p: [V2], _ q: [V2]) -> Double {
        if overlap(p, q) { return 0 }
        var best = Double.infinity
        for i in p.indices {
            let a = p[i], b = p[(i + 1) % p.count]
            for v in q { best = min(best, pointSegment(v, a, b)) }
        }
        for i in q.indices {
            let a = q[i], b = q[(i + 1) % q.count]
            for v in p { best = min(best, pointSegment(v, a, b)) }
        }
        return best
    }

    private static func pointSegment(_ p: V2, _ a: V2, _ b: V2) -> Double {
        let e = b - a
        let l2 = simd_length_squared(e)
        let t = l2 > 0 ? min(max(simd_dot(p - a, e) / l2, 0), 1) : 0
        return simd_length(p - (a + e * t))
    }

    private static func overlap(_ p: [V2], _ q: [V2]) -> Bool {
        for poly in [p, q] {
            for i in poly.indices {
                let e = poly[(i + 1) % poly.count] - poly[i]
                guard simd_length_squared(e) > 0 else { continue }
                let n = V2(-e.y, e.x)
                let a = p.map { simd_dot($0, n) }, b = q.map { simd_dot($0, n) }
                if a.max()! < b.min()! || b.max()! < a.min()! { return false }
            }
        }
        return true
    }
}
