import AppKit
import Foundation
import RealityKit
import RoomsmithCore
import simd

enum GizmoHandle: Hashable {
    case axisX, axisY, axisZ, ring

    var axis: D3? {
        switch self {
        case .axisX: D3(1, 0, 0)
        case .axisY: D3(0, 1, 0)
        case .axisZ: D3(0, 0, 1)
        case .ring: nil
        }
    }
    var label: String {
        switch self {
        case .axisX: "X"
        case .axisY: "Y"
        case .axisZ: "Z"
        case .ring: "Rotation"
        }
    }
}

/// Move/rotate widget: three arrows (X red, Y green, Z blue) and a ring around Z.
///
/// The entity hierarchy is built in document axes with unit size and carries the `-90 degrees about X` orientation
/// of the content root, so a child at (1, 0, 0) is one gizmo length along document X. The renderer scales the root
/// every frame so the widget keeps a constant size on screen. Hit testing happens in screen space (see `hit`).
@MainActor
final class Gizmo {
    /// Screen size of the arrows in points.
    static let screenLength = 110.0
    static let ringRadius = 0.72
    static let tolerance = 9.0

    let root = Entity()
    private var parts: [GizmoHandle: [ModelEntity]] = [:]
    private var colors: [GizmoHandle: NSColor] = [:]
    private var highlighted: GizmoHandle?
    private(set) var available: Set<GizmoHandle> = []

    init() {
        root.isEnabled = false
        let red = NSColor(srgbRed: 0.95, green: 0.25, blue: 0.22, alpha: 1)
        let green = NSColor(srgbRed: 0.25, green: 0.78, blue: 0.32, alpha: 1)
        let blue = NSColor(srgbRed: 0.25, green: 0.48, blue: 1.0, alpha: 1)
        let ring = NSColor(srgbRed: 1.0, green: 0.74, blue: 0.2, alpha: 1)
        colors = [.axisX: red, .axisY: green, .axisZ: blue, .ring: ring]
        // Cylinders and cones point along +Y; rotate that onto the wanted axis.
        arrow(.axisX, rotation: simd_quatf(angle: -.pi / 2, axis: SIMD3(0, 0, 1)), dir: SIMD3(1, 0, 0))
        arrow(.axisY, rotation: simd_quatf(angle: 0, axis: SIMD3(0, 0, 1)), dir: SIMD3(0, 1, 0))
        arrow(.axisZ, rotation: simd_quatf(angle: .pi / 2, axis: SIMD3(1, 0, 0)), dir: SIMD3(0, 0, 1))
        if let mesh = SceneMeshes.torus(radius: Float(Self.ringRadius), tube: 0.018) {
            let e = ModelEntity(mesh: mesh, materials: [SceneMaterials.unlit(ring)])
            sortOnTop(e)
            root.addChild(e)
            parts[.ring] = [e]
        }
    }

    private func arrow(_ h: GizmoHandle, rotation: simd_quatf, dir: SIMD3<Float>) {
        let color = colors[h]!
        let m = SceneMaterials.unlit(color)
        let shaft = ModelEntity(mesh: .generateCylinder(height: 0.68, radius: 0.017), materials: [m])
        shaft.position = dir * 0.46
        shaft.orientation = rotation
        let tip = ModelEntity(mesh: .generateCone(height: 0.2, radius: 0.055), materials: [m])
        tip.position = dir * 0.9
        tip.orientation = rotation
        for e in [shaft, tip] { sortOnTop(e); root.addChild(e) }
        parts[h] = [shaft, tip]
    }

    private func sortOnTop(_ e: ModelEntity) {
        e.components.set(ModelSortGroupComponent(group: ModelSortGroup(depthPass: .postPass), order: 10))
    }

    /// Shows the widget with the given handles, or hides it when empty.
    func configure(handles: Set<GizmoHandle>) {
        available = handles
        root.isEnabled = !handles.isEmpty
        for (h, list) in parts { for e in list { e.isEnabled = handles.contains(h) } }
    }

    func highlight(_ h: GizmoHandle?) {
        guard h != highlighted else { return }
        highlighted = h
        for (k, list) in parts {
            let base = colors[k]!
            let c = (k == h) ? (base.blended(withFraction: 0.55, of: .white) ?? base) : base
            for e in list { e.model?.materials = [SceneMaterials.unlit(c)] }
        }
    }

    /// Places the widget: `origin` in document mm, `mmPerUnit` = length of one gizmo unit in mm.
    func place(origin: D3, mmPerUnit: Double) {
        root.position = SceneCoords.world(origin)
        root.orientation = simd_quatf(angle: -.pi / 2, axis: SIMD3(1, 0, 0))
        root.scale = SIMD3(repeating: Float(mmPerUnit / 1000))
    }

    // MARK: Hit testing

    /// Screen-space hit test. Returns the handle closest to the cursor within `tolerance` points.
    /// `point` is in view points (origin bottom-left).
    func hit(point: SIMD2<Double>, origin: D3, rig: CameraRig, viewSize: CGSize, mmPerUnit: Double) -> GizmoHandle? {
        guard root.isEnabled, viewSize.width > 0, viewSize.height > 0 else { return nil }
        let aspect = Double(viewSize.width / viewSize.height)
        func screen(_ p: D3) -> SIMD2<Double>? {
            guard let n = rig.project(p, aspect: aspect) else { return nil }
            return SIMD2((n.x + 1) / 2 * Double(viewSize.width), (n.y + 1) / 2 * Double(viewSize.height))
        }
        guard let o = screen(origin) else { return nil }
        var best: (GizmoHandle, Double)?
        func offer(_ h: GizmoHandle, _ d: Double) {
            guard d <= Self.tolerance else { return }
            if best == nil || d < best!.1 - 0.5 { best = (h, d) }
        }
        for h in [GizmoHandle.axisX, .axisY, .axisZ] where available.contains(h) {
            guard let axis = h.axis, let tip = screen(origin + axis * mmPerUnit * 1.0) else { continue }
            offer(h, Self.distance(point, toSegment: o, tip))
        }
        if available.contains(.ring) {
            let r = Self.ringRadius * mmPerUnit
            var prev: SIMD2<Double>?
            let n = 72
            for i in 0...n {
                let a = Double(i) / Double(n) * 2 * .pi
                let p = screen(origin + D3(cos(a) * r, sin(a) * r, 0))
                if let p, let q = prev { offer(.ring, Self.distance(point, toSegment: q, p)) }
                prev = p
            }
        }
        return best?.0
    }

    static func distance(_ p: SIMD2<Double>, toSegment a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
        let ab = b - a
        let len2 = simd_length_squared(ab)
        guard len2 > 1e-9 else { return simd_length(p - a) }
        let t = min(max(simd_dot(p - a, ab) / len2, 0), 1)
        return simd_length(p - (a + ab * t))
    }

    // MARK: Drag maths

    /// Parameter (mm) along the axis through `origin` where it comes closest to the mouse ray. nil when the ray is
    /// almost parallel to the axis (the position would be unstable).
    static func axisParameter(rayOrigin e: D3, rayDir d: D3, origin o: D3, axis a: D3) -> Double? {
        let w0 = o - e
        let b = simd_dot(a, d)
        let denom = 1 - b * b
        guard denom > 1e-4 else { return nil }
        let d0 = simd_dot(a, w0), e0 = simd_dot(d, w0)
        return (b * e0 - d0) / denom
    }

    /// Angle (degrees, counter-clockwise seen from above) of the ray's hit on the horizontal plane at `z`, around
    /// `pivot`. nil when the ray is nearly horizontal.
    static func ringAngle(rayOrigin e: D3, rayDir d: D3, pivot: D3, z: Double) -> Double? {
        guard abs(d.z) > 0.02 else { return nil }
        let t = (z - e.z) / d.z
        guard t > 0 else { return nil }
        let p = e + d * t
        return atan2(p.y - pivot.y, p.x - pivot.x) * 180 / .pi
    }

    /// Wraps an angle difference into (-180, 180].
    static func wrap(_ deg: Double) -> Double {
        var d = deg.truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 } else if d <= -180 { d += 360 }
        return d
    }
}
