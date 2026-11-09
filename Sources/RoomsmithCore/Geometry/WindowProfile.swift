import Foundation

/// Profile sizes and the motion rules of windows and balcony doors. Every size is a design default, not measured
/// from a real window system (rule: no value here is presented as a measurement). The pure functions decide how many
/// sashes a window really gets and whether they can move; the mesh, the walk collider, the motion state and the agent
/// tools all use `effectiveMotion`, so they never disagree.
public enum WindowProfile {
    /// Depth of the sash on each face is the frame half depth minus this inset (default, not measured).
    public static let sashInset = 8.0
    /// Thinnest sash half depth (default, not measured).
    public static let minSashHalfDepth = 4.0
    /// Widest frame half depth taken from the wall (default, not measured).
    public static let maxFrameHalfDepth = 40.0
    /// Sash member width limit (default, not measured).
    public static let sashMemberMax = 40.0
    /// Lower rail of a balcony door sash (default, not measured).
    public static let balconyBottomRail = 100.0
    /// Hinge barrel radius (default, not measured).
    public static let hingeRadius = 5.0
    /// Window handles are the door handle shape scaled by this (default, not measured).
    public static let handleScale = 0.7
    /// Width of the frame step (rebate) on the inner edge of the frame members (default, not measured).
    public static let rebateWidth = 12.0
    /// How far the rebate steps back from the frame faces (default, not measured).
    public static let rebateStep = 4.0
    /// Glazing bead around the glass pane: width and how far it sits back from the sash faces (default, not measured).
    public static let beadWidth = 10.0
    public static let beadSetback = 6.0
    /// Smallest sash that is still built and moved (default, not measured).
    public static let minSashWidth = 200.0
    public static let minSashHeight = 300.0
    /// Angle of a tilted sash and of a turned sash, degrees (default, not measured).
    public static let tiltOpenDeg = 10.0
    public static let turnOpenDeg = 90.0

    /// Half depth of the sash for a wall of `thickness` mm: `max(min(half, 40) - 8, 4)`.
    public static func sashHalfDepth(wallThickness: Double) -> Double {
        max(min(wallThickness / 2, maxFrameHalfDepth) - sashInset, minSashHalfDepth)
    }

    /// Clearance a sash of length `l` and depth `2 * ds` needs at its free edge: its rear corner sweeps up to
    /// `sqrt(l^2 + 4 ds^2)` from the pivot, plus 1 mm.
    public static func freeClearance(_ l: Double, ds: Double) -> Double {
        (((l * l + 4 * ds * ds).squareRoot() - l)).rounded(.up) + 1
    }

    public static func isMovableStyle(_ s: OpeningStyle) -> Bool {
        s == .tiltTurn1 || s == .tiltTurn2 || s == .balconyDoor || s == .balconyDoor2
    }

    public static func wantsTwoSashes(_ s: OpeningStyle) -> Bool { s == .tiltTurn2 || s == .balconyDoor2 }

    public struct Motion: Sendable, Equatable {
        /// 0 = fixed glazing, 1 or 2 movable sashes.
        public var sashCount: Int
        public var movable: Bool
        /// Final sash size in mm (0 when not movable).
        public var sashWidth: Double
        public var sashHeight: Double
    }

    /// The one decision function. `innerWidth` / `innerHeight` are the frame's inner rectangle in mm.
    public static func effectiveMotion(style: OpeningStyle, innerWidth: Double, innerHeight: Double, ds: Double) -> Motion {
        let none = Motion(sashCount: 0, movable: false, sashWidth: 0, sashHeight: 0)
        guard isMovableStyle(style), innerWidth > 0, innerHeight > 0 else { return none }
        func width(_ n: Int) -> Double {
            let a = innerWidth / Double(n)
            let c = freeClearance(a - freeClearance(a, ds: ds), ds: ds)
            return a - c
        }
        let h = innerHeight - freeClearance(innerHeight, ds: ds)
        guard h >= minSashHeight else { return none }
        var n = wantsTwoSashes(style) ? 2 : 1
        if n == 2, width(2) < minSashWidth { n = 1 }
        let w = width(n)
        guard w >= minSashWidth else { return none }
        return Motion(sashCount: n, movable: true, sashWidth: w, sashHeight: h)
    }

    /// One sash in wall-local coordinates (x along the wall, z up).
    public struct SashRect: Sendable, Equatable {
        public var x0: Double, x1: Double, z0: Double, z1: Double
        /// True when the vertical hinge edge is the low-x edge.
        public var hingeAtMin: Bool
        public var hasHandle: Bool
        public var width: Double { x1 - x0 }
        public var height: Double { z1 - z0 }
        public var hingeX: Double { hingeAtMin ? x0 : x1 }
    }

    /// Sash rectangles inside the inner rectangle (x0, x1, z0, z1). Empty for non-movable openings.
    public static func sashRects(style: OpeningStyle, flipped: Bool, innerX0: Double, innerX1: Double, innerZ0: Double, innerZ1: Double,
                                 ds: Double) -> [SashRect] {
        let m = effectiveMotion(style: style, innerWidth: innerX1 - innerX0, innerHeight: innerZ1 - innerZ0, ds: ds)
        guard m.movable else { return [] }
        let z1 = innerZ0 + m.sashHeight
        if m.sashCount == 1 {
            // Handle on the free edge; `flipped` mirrors the hinge to the high-x side.
            if !flipped { return [SashRect(x0: innerX0, x1: innerX0 + m.sashWidth, z0: innerZ0, z1: z1, hingeAtMin: true, hasHandle: true)] }
            return [SashRect(x0: innerX1 - m.sashWidth, x1: innerX1, z0: innerZ0, z1: z1, hingeAtMin: false, hasHandle: true)]
        }
        let left = SashRect(x0: innerX0, x1: innerX0 + m.sashWidth, z0: innerZ0, z1: z1, hingeAtMin: true, hasHandle: !flipped)
        let right = SashRect(x0: innerX1 - m.sashWidth, x1: innerX1, z0: innerZ0, z1: z1, hingeAtMin: false, hasHandle: flipped)
        return [left, right]
    }

    /// Sash member width of a rectangle (same rule the sash mesh uses).
    public static func sashMember(width: Double, height: Double) -> Double { min(sashMemberMax, width / 6, height / 6) }
}

/// How an opening is open in the view. Doors only turn.
public enum OpeningMode: String, Sendable, Hashable, CaseIterable { case closed, turn, tilt }
