import Foundation
import simd

/// Separate, movable sashes of windows and balcony doors.
extension Meshes {
    /// Where a sash pivots and how far it opens. The sash mesh is built around its pivot: local x along the wall from
    /// the hinge edge, y through the depth (the pivot face is y = 0), z up from the sash bottom. Both pivots lie on the
    /// sash face of the swing side, so the sash swings and tilts away from the frame. World position of a sash vertex `p`:
    /// `pivot + Rz(closedYawDeg + turn * turnOpenDeg) * Rx(tilt * tiltOpenDeg) * p`, with `turn` and `tilt` in 0...1.
    public struct SashPlacement: Sendable, Equatable {
        public var index: Int
        /// Hinge edge on the swing-side face at the sash bottom, world mm.
        public var pivot: SIMD3<Double>
        /// Direction of the wall (angle of the local x axis about Z).
        public var closedYawDeg: Double
        /// Signed angle about Z that turns the free edge to the swing side when fully open.
        public var turnOpenDeg: Double
        /// Signed angle about the local x axis that moves the top edge to the swing side when fully tilted.
        public var tiltOpenDeg: Double
        public var width: Double
        public var height: Double
        /// The sash carrying the handle; it is the only one that tilts when there are two.
        public var hasHandle: Bool

        /// Sash-local point to world for the given poses.
        public func world(_ p: SIMD3<Double>, turn: Double = 0, tilt: Double = 0) -> SIMD3<Double> {
            let rx = simd_quatd(angle: tilt * tiltOpenDeg * .pi / 180, axis: SIMD3(1, 0, 0))
            let rz = simd_quatd(angle: (closedYawDeg + turn * turnOpenDeg) * .pi / 180, axis: SIMD3(0, 0, 1))
            return pivot + rz.act(rx.act(p))
        }
    }

    public struct WindowSash: Sendable {
        public var placement: SashPlacement
        public var mesh: MeshData
    }

    /// Facts of a window needed for its sashes: frame inner rectangle and sash half depth.
    struct WindowInfo {
        var cut: Cut
        var ft: Double
        var inner: (x0: Double, x1: Double, z0: Double, z1: Double)
        var ds: Double
        var motion: WindowProfile.Motion
    }

    static func windowInfo(_ o: Opening, wall: Wall) -> WindowInfo? {
        guard o.kind == .window else { return nil }
        let ax = Geo.axis(wall.start, wall.end)
        guard ax.length > 0, let cut = cuts(of: wall, openings: [o], length: ax.length).first else { return nil }
        let ft = min(Double(o.frameWidth), (cut.s1 - cut.s0) / 3, (cut.z1 - cut.z0) / 3)
        let inner = (x0: cut.s0 + ft, x1: cut.s1 - ft, z0: cut.z0 + ft, z1: cut.z1 - ft)
        let ds = WindowProfile.sashHalfDepth(wallThickness: Double(wall.thickness))
        let style = OpeningStyle.windowStyles.contains(o.style) ? o.style : .fixed
        let motion = WindowProfile.effectiveMotion(style: style, innerWidth: inner.x1 - inner.x0, innerHeight: inner.z1 - inner.z0, ds: ds)
        return WindowInfo(cut: cut, ft: ft, inner: inner, ds: ds, motion: motion)
    }

    /// The decision of `WindowProfile.effectiveMotion` for a window on `wall`; nil for non-windows.
    public static func windowMotion(_ o: Opening, wall: Wall) -> WindowProfile.Motion? { windowInfo(o, wall: wall)?.motion }

    /// The movable sashes of a window (empty for fixed or too small windows, and for non-windows), each with its pivot and
    /// its mesh in sash-local coordinates. Closed, `placement.world` puts every vertex where `openingFrame` has it.
    public static func windowSashes(_ o: Opening, wall: Wall, baseZ: MM) -> [WindowSash] {
        guard let info = windowInfo(o, wall: wall) else { return [] }
        let style = OpeningStyle.windowStyles.contains(o.style) ? o.style : .fixed
        let rects = WindowProfile.sashRects(style: style, flipped: o.flipped, innerX0: info.inner.x0, innerX1: info.inner.x1,
                                            innerZ0: info.inner.z0, innerZ1: info.inner.z1, ds: info.ds)
        guard !rects.isEmpty else { return [] }
        let ax = Geo.axis(wall.start, wall.end)
        let face: Double = o.inward ? 1 : -1
        let yaw = atan2(ax.dir.y, ax.dir.x) * 180 / .pi
        let origin = V3(Double(wall.start.x), Double(wall.start.y), Double(baseZ))
        let l = OpeningDetail.Local(o: origin, x: V3(ax.dir.x, ax.dir.y, 0), y: V3(ax.normal.x, ax.normal.y, 0), z: V3(0, 0, 1))
        var out: [WindowSash] = []
        for (i, rc) in rects.enumerated() {
            let pivot = OpeningDetail.sashLocal(l, rc, face: face, ds: info.ds).o
            var m = MeshData()
            // Same builder as the closed frame, but in the identity frame around the pivot.
            OpeningDetail.addSashOnly(&m, o, style: style, rect: rc, innerZ0: info.inner.z0, innerZ1: info.inner.z1, cutZ0: info.cut.z0,
                                      face: face, ds: info.ds)
            let e: Double = rc.hingeAtMin ? 1 : -1
            out.append(WindowSash(
                placement: SashPlacement(index: i, pivot: pivot, closedYawDeg: yaw, turnOpenDeg: face * e * WindowProfile.turnOpenDeg,
                                         tiltOpenDeg: -face * WindowProfile.tiltOpenDeg, width: rc.width, height: rc.height,
                                         hasHandle: rc.hasHandle),
                mesh: m.regrouped()))
        }
        return out
    }
}
