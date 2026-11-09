import Foundation
import simd

/// Detail geometry of doors and windows: panel cassettes, glazing, sliding panels, glazing bars, sashes, handles and
/// hinges. `Meshes` calls into this from the door-leaf and window branches; everything here is built in a local frame
/// so the same code serves the swinging leaf (hinge-local, rotated by the renderer) and the closed leaf / window in
/// world space.
enum OpeningDetail {
    /// Orthonormal frame: local (a, b, c) maps to `o + x*a + y*b + z*c`.
    struct Local {
        var o: V3
        var x: V3
        var y: V3
        var z: V3
        static let identity = Local(o: V3(0, 0, 0), x: V3(1, 0, 0), y: V3(0, 1, 0), z: V3(0, 0, 1))
        func p(_ a: Double, _ b: Double, _ c: Double) -> V3 { o + x * a + y * b + z * c }
        var axes: [V3] { [x, y, z] }
    }

    /// Rectangle in leaf-local x / z.
    struct Rect: Equatable {
        var x0: Double, x1: Double, z0: Double, z1: Double
    }

    static let leafHalf = 20.0
    static let cassetteRaise = 6.0
    static let barWidth = 24.0

    static func glassRole(_ g: OpeningGlass) -> MeshRole {
        switch g { case .clear: .glass; case .frosted: .glassFrosted; case .tinted: .glassTinted }
    }

    // MARK: layout (pure, tested)

    /// Raised cassette rectangles of a panel door leaf (`panel2`: upper + lower, `panel4`: 2 x 2); empty for other styles.
    static func cassetteRects(style: OpeningStyle, width w: Double, z0: Double, z1: Double) -> [Rect] {
        let rows: Int, cols: Int
        switch style {
        case .panel2: rows = 2; cols = 1
        case .panel4: rows = 2; cols = 2
        default: return []
        }
        let stile = min(110.0, w / 4), top = min(110.0, (z1 - z0) / 8), bottom = min(160.0, (z1 - z0) / 6), gap = min(90.0, w / 8)
        let ax0 = stile, ax1 = w - stile, az0 = z0 + bottom, az1 = z1 - top
        guard ax1 - ax0 > gap * Double(cols), az1 - az0 > gap * Double(rows) else { return [] }
        let cw = (ax1 - ax0 - gap * Double(cols - 1)) / Double(cols)
        let ch = (az1 - az0 - gap * Double(rows - 1)) / Double(rows)
        var out: [Rect] = []
        for r in 0..<rows {
            for c in 0..<cols {
                let x = ax0 + Double(c) * (cw + gap), z = az0 + Double(r) * (ch + gap)
                out.append(Rect(x0: x, x1: x + cw, z0: z, z1: z + ch))
            }
        }
        return out
    }

    /// Centre positions of `count` evenly spaced bars that divide [a, b] into count + 1 parts.
    static func barPositions(count: Int, from a: Double, to b: Double) -> [Double] {
        guard count > 0, b > a else { return [] }
        return (1...count).map { a + (b - a) * Double($0) / Double(count + 1) }
    }

    // MARK: door leaf

    /// Adds the leaf to `m`. Local x runs from the hinge edge (0) to the free edge (`w`), y is the leaf thickness
    /// direction, z the height (`z0`..`z1`). `swing` is +1 when the leaf opens toward +y, otherwise -1.
    static func addDoorLeaf(_ m: inout MeshData, _ o: Opening, local l: Local, width w: Double, z0: Double, z1: Double, swing: Double) {
        let t = leafHalf, r = MeshRole.openingFrame
        let style = OpeningStyle.doorStyles.contains(o.style) ? o.style : .smooth
        switch style {
        case .smooth, .panel2, .panel4:
            m.addBox(l, 0, w, -t, t, z0, z1, r)
            for c in cassetteRects(style: style, width: w, z0: z0, z1: z1) {
                m.addBox(l, c.x0, c.x1, t, t + cassetteRaise, c.z0, c.z1, r)
                m.addBox(l, c.x0, c.x1, -t - cassetteRaise, -t, c.z0, c.z1, r)
            }
        case .glass:
            let stile = min(100.0, w / 4), top = min(100.0, (z1 - z0) / 6), bottom = min(200.0, (z1 - z0) / 5)
            m.addBox(l, 0, stile, -t, t, z0, z1, r)
            m.addBox(l, w - stile, w, -t, t, z0, z1, r)
            m.addBox(l, stile, w - stile, -t, t, z0, z0 + bottom, r)
            m.addBox(l, stile, w - stile, -t, t, z1 - top, z1, r)
            addGlazing(&m, l, Rect(x0: stile, x1: w - stile, z0: z0 + bottom, z1: z1 - top), o)
        case .sliding:
            addSlidingPanels(&m, l, o, width: w, z0: z0, z1: z1)
        default:
            break
        }
        guard style != .sliding else { return }
        // Hinges on the face the leaf does not swing toward.
        let hingeFace = -swing
        for z in [z0 + 220, (z0 + z1) / 2, z1 - 260] {
            m.addPrism(l, axis: 2, u: 8, v: hingeFace * (t + 5), radius: 8, from: z - 55, to: z + 55, sides: 10, .hardware)
        }
        let hx = max(w - 55, w / 2)
        let hz = min(max(z0 + 1050, z0 + 100), z1 - 100)
        for side in [-1.0, 1.0] {
            m.addHandle(l, o.handle, x: hx, z: hz, faceY: side * t, out: side, along: (0, -1), scale: 1)
        }
    }

    private static func addSlidingPanels(_ m: inout MeshData, _ l: Local, _ o: Opening, width w: Double, z0: Double, z1: Double) {
        let pw = w / 2 + 30, half = 10.0, stile = 50.0, r = MeshRole.openingFrame
        // Top and bottom track.
        m.addBox(l, 0, w, -35, 35, z1 - 30, z1, r)
        m.addBox(l, 0, w, -35, 35, z0, z0 + 12, r)
        let panels: [(x0: Double, y0: Double, y1: Double)] = [(0, -28, -28 + 2 * half), (w - pw, 8, 8 + 2 * half)]
        for (i, pn) in panels.enumerated() {
            let x0 = pn.x0, x1 = pn.x0 + pw, zb = z0 + 12, zt = z1 - 30
            m.addBox(l, x0, x0 + stile, pn.y0, pn.y1, zb, zt, r)
            m.addBox(l, x1 - stile, x1, pn.y0, pn.y1, zb, zt, r)
            m.addBox(l, x0 + stile, x1 - stile, pn.y0, pn.y1, zb, zb + stile, r)
            m.addBox(l, x0 + stile, x1 - stile, pn.y0, pn.y1, zt - stile, zt, r)
            let cy = (pn.y0 + pn.y1) / 2
            addGlazing(&m, l, Rect(x0: x0 + stile, x1: x1 - stile, z0: zb + stile, z1: zt - stile), o, centreY: cy)
            // Handle on the outward face, at the leading stile.
            let out: Double = i == 0 ? -1 : 1
            let hx = i == 0 ? x1 - stile / 2 : x0 + stile / 2
            m.addHandle(l, o.handle, x: hx, z: min(max(z0 + 1050, z0 + 100), z1 - 100), faceY: out > 0 ? pn.y1 : pn.y0, out: out,
                        along: (0, i == 0 ? -1 : 1), scale: 1)
        }
    }

    /// Glass pane plus glazing bars for `o.mullionCols` x `o.mullionRows` within `rect`.
    private static func addGlazing(_ m: inout MeshData, _ l: Local, _ rect: Rect, _ o: Opening, centreY: Double = 0, thickness: Double = 3) {
        guard rect.x1 > rect.x0, rect.z1 > rect.z0 else { return }
        m.addBox(l, rect.x0, rect.x1, centreY - thickness, centreY + thickness, rect.z0, rect.z1, glassRole(o.glassType))
        addBars(&m, l, rect, cols: o.mullionCols, rows: o.mullionRows, centreY: centreY)
    }

    private static func addBars(_ m: inout MeshData, _ l: Local, _ rect: Rect, cols: Int, rows: Int, centreY: Double) {
        let hw = barWidth / 2, hd = 6.0
        for x in barPositions(count: cols, from: rect.x0, to: rect.x1) {
            m.addBox(l, x - hw, x + hw, centreY - hd, centreY + hd, rect.z0, rect.z1, .openingFrame)
        }
        for z in barPositions(count: rows, from: rect.z0, to: rect.z1) {
            m.addBox(l, rect.x0, rect.x1, centreY - hd, centreY + hd, z - hw, z + hw, .openingFrame)
        }
    }

    // MARK: windows

    /// Window frame (with a rebate step on its inner edge), sash(es), glass, bars and hardware. Local x runs along the
    /// wall (`s`), y is the wall normal (origin on the wall axis), z the height above the wall base. Hinges belong to the
    /// frame; with `includeSashes` false the moving sashes (body, glass, bars, handle) are left out, see
    /// `Meshes.windowSashes`. Which sashes exist is decided by `WindowProfile.sashRects`.
    static func addWindow(_ m: inout MeshData, _ o: Opening, local l: Local, s0: Double, s1: Double, z0: Double, z1: Double,
                          ft: Double, depth d: Double, includeSashes: Bool = true) {
        let r = MeshRole.openingFrame
        let rb = min(WindowProfile.rebateWidth, ft / 2), step = min(WindowProfile.rebateStep, d / 2)
        // Jambs, head and sill: full depth outside, the inner `rb` strip steps back from both faces.
        m.addBox(l, s0, s0 + ft - rb, -d, d, z0 + ft, z1 - ft, r)
        m.addBox(l, s0 + ft - rb, s0 + ft, -d + step, d - step, z0 + ft, z1 - ft, r)
        m.addBox(l, s1 - ft + rb, s1, -d, d, z0 + ft, z1 - ft, r)
        m.addBox(l, s1 - ft, s1 - ft + rb, -d + step, d - step, z0 + ft, z1 - ft, r)
        m.addBox(l, s0, s1, -d, d, z0, z0 + ft - rb, r)
        m.addBox(l, s0 + ft, s1 - ft, -d + step, d - step, z0 + ft - rb, z0 + ft, r)
        m.addBox(l, s0, s1, -d, d, z1 - ft + rb, z1, r)
        m.addBox(l, s0 + ft, s1 - ft, -d + step, d - step, z1 - ft, z1 - ft + rb, r)
        let inner = Rect(x0: s0 + ft, x1: s1 - ft, z0: z0 + ft, z1: z1 - ft)
        guard inner.x1 > inner.x0, inner.z1 > inner.z0 else { return }
        let style = OpeningStyle.windowStyles.contains(o.style) ? o.style : .fixed
        let face: Double = o.inward ? 1 : -1
        let ds = max(d - WindowProfile.sashInset, WindowProfile.minSashHalfDepth)
        let rects = WindowProfile.sashRects(style: style, flipped: o.flipped, innerX0: inner.x0, innerX1: inner.x1,
                                            innerZ0: inner.z0, innerZ1: inner.z1, ds: ds)
        guard !rects.isEmpty else {
            addGlazing(&m, l, inner, o)
            return
        }
        let balcony = style == .balconyDoor || style == .balconyDoor2
        for rc in rects {
            let hx = rc.hingeAtMin ? rc.x0 + 6 : rc.x1 - 6
            addSashHinges(&m, l, Rect(x0: rc.x0, x1: rc.x1, z0: rc.z0, z1: rc.z1), hingeX: hx, faceY: face * ds, out: face)
        }
        guard includeSashes else { return }
        for rc in rects {
            let sl = sashLocal(l, rc, face: face, ds: ds)
            addSashBody(&m, sl, o, rc, depth: ds, face: face, bottomRail: balcony ? WindowProfile.balconyBottomRail : nil,
                        handleZ: balcony ? min(max(z0 + 1050, inner.z0 + 150), inner.z1 - 150) : (rc.z0 + rc.z1) / 2)
        }
    }

    /// One sash alone in the identity frame around its pivot (see `Meshes.windowSashes`).
    static func addSashOnly(_ m: inout MeshData, _ o: Opening, style: OpeningStyle, rect rc: WindowProfile.SashRect, innerZ0: Double,
                            innerZ1: Double, cutZ0: Double, face: Double, ds: Double) {
        let balcony = style == .balconyDoor || style == .balconyDoor2
        addSashBody(&m, .identity, o, rc, depth: ds, face: face, bottomRail: balcony ? WindowProfile.balconyBottomRail : nil,
                    handleZ: balcony ? min(max(cutZ0 + 1050, innerZ0 + 150), innerZ1 - 150) : (rc.z0 + rc.z1) / 2)
    }

    /// Sash-local frame: origin at the hinge edge, on the sash face toward the swing side, at the sash bottom. This is the
    /// pivot of the turn and the tilt (see `SashPlacement`); the axes stay those of the wall-local frame `l`.
    static func sashLocal(_ l: Local, _ rc: WindowProfile.SashRect, face: Double, ds: Double) -> Local {
        Local(o: l.p(rc.hingeX, face * ds, rc.z0), x: l.x, y: l.y, z: l.z)
    }

    /// One sash in its sash-local frame (see `sashLocal`): x from the hinge edge, y through the depth (the pivot face is
    /// y = 0, the sash lies at `-face * 2 ds ... 0`), z from the sash bottom.
    private static func addSashBody(_ m: inout MeshData, _ l: Local, _ o: Opening, _ rc: WindowProfile.SashRect, depth ds: Double,
                                    face: Double, bottomRail: Double?, handleZ: Double) {
        let w = rc.width, h = rc.height
        let x0 = rc.hingeAtMin ? 0.0 : -w, x1 = x0 + w
        let yc = -face * ds, ya = yc - ds, yb = yc + ds
        let sw = WindowProfile.sashMember(width: w, height: h)
        let bottom = min(bottomRail ?? sw, h / 3)
        let r = MeshRole.openingFrame
        m.addBox(l, x0, x0 + sw, ya, yb, 0, h, r)
        m.addBox(l, x1 - sw, x1, ya, yb, 0, h, r)
        m.addBox(l, x0 + sw, x1 - sw, ya, yb, 0, bottom, r)
        m.addBox(l, x0 + sw, x1 - sw, ya, yb, h - sw, h, r)
        let g = Rect(x0: x0 + sw, x1: x1 - sw, z0: bottom, z1: h - sw)
        addGlazing(&m, l, g, o, centreY: yc)
        // Glazing bead: a thin frame around the pane, set back from both sash faces.
        let bw = min(WindowProfile.beadWidth, (g.x1 - g.x0) / 4, (g.z1 - g.z0) / 4), bd = max(ds - WindowProfile.beadSetback, 1)
        if bw > 0 {
            m.addBox(l, g.x0, g.x1, yc - bd, yc + bd, g.z0, g.z0 + bw, r)
            m.addBox(l, g.x0, g.x1, yc - bd, yc + bd, g.z1 - bw, g.z1, r)
            m.addBox(l, g.x0, g.x0 + bw, yc - bd, yc + bd, g.z0 + bw, g.z1 - bw, r)
            m.addBox(l, g.x1 - bw, g.x1, yc - bd, yc + bd, g.z0 + bw, g.z1 - bw, r)
        }
        guard rc.hasHandle else { return }
        // Handle on the free vertical edge, on the swing-side face (local y = 0).
        let edgeX = rc.hingeAtMin ? x1 - sw / 2 : x0 + sw / 2
        m.addHandle(l, o.handle, x: edgeX, z: handleZ - rc.z0, faceY: 0, out: face, along: (2, -1), scale: WindowProfile.handleScale,
                    role: .windowHardware)
    }

    private static func addSashHinges(_ m: inout MeshData, _ l: Local, _ rc: Rect, hingeX: Double, faceY: Double, out: Double) {
        for z in [rc.z0 + (rc.z1 - rc.z0) * 0.15, rc.z1 - (rc.z1 - rc.z0) * 0.15] {
            m.addPrism(l, axis: 2, u: hingeX, v: faceY + out * 4, radius: WindowProfile.hingeRadius, from: z - 30, to: z + 30, sides: 8,
                       .windowHardware)
        }
    }
}

// MARK: - Mesh building blocks

extension MeshData {
    /// Axis-aligned box in a local frame (each side is a flat quad with its own normal).
    mutating func addBox(_ l: OpeningDetail.Local, _ x0: Double, _ x1: Double, _ y0: Double, _ y1: Double,
                         _ z0: Double, _ z1: Double, _ role: MeshRole) {
        guard x1 > x0, y1 > y0, z1 > z0 else { return }
        func c(_ x: Double, _ y: Double, _ z: Double) -> V3 { l.p(x, y, z) }
        addQuad([c(x0, y0, z0), c(x0, y1, z0), c(x0, y1, z1), c(x0, y0, z1)], normal: -l.x, role: role)
        addQuad([c(x1, y0, z0), c(x1, y1, z0), c(x1, y1, z1), c(x1, y0, z1)], normal: l.x, role: role)
        addQuad([c(x0, y0, z0), c(x1, y0, z0), c(x1, y0, z1), c(x0, y0, z1)], normal: -l.y, role: role)
        addQuad([c(x0, y1, z0), c(x1, y1, z0), c(x1, y1, z1), c(x0, y1, z1)], normal: l.y, role: role)
        addQuad([c(x0, y0, z0), c(x1, y0, z0), c(x1, y1, z0), c(x0, y1, z0)], normal: -l.z, role: role)
        addQuad([c(x0, y0, z1), c(x1, y0, z1), c(x1, y1, z1), c(x0, y1, z1)], normal: l.z, role: role)
    }

    /// Cylinder along local `axis` (0 x, 1 y, 2 z) between `from` and `to`. `u` / `v` are the centre's coordinates on
    /// the other two axes, in the order (axis+1, axis+2) modulo 3.
    mutating func addPrism(_ l: OpeningDetail.Local, axis: Int, u cu: Double, v cv: Double, radius: Double,
                           from a0: Double, to a1: Double, sides: Int, _ role: MeshRole) {
        guard a1 > a0, radius > 0, sides >= 3 else { return }
        let ax = l.axes
        let a = ax[axis], ub = ax[(axis + 1) % 3], vb = ax[(axis + 2) % 3]
        let centre = l.o + ub * cu + vb * cv
        func ring(_ k: Int) -> V3 {
            let t = 2 * Double.pi * Double(k) / Double(sides)
            return ub * cos(t) + vb * sin(t)
        }
        for k in 0..<sides {
            let r0 = ring(k), r1 = ring(k + 1)
            let n = simd_normalize(r0 + r1)
            addQuad([centre + r0 * radius + a * a0, centre + r1 * radius + a * a0,
                     centre + r1 * radius + a * a1, centre + r0 * radius + a * a1], normal: n, role: role)
        }
        let capStart = indices.count
        for (pos, n) in [(a0, -a), (a1, a)] {
            let c = addVertex(centre + a * pos, n, SIMD2(0, 0))
            var ids: [UInt32] = []
            for k in 0..<sides { ids.append(addVertex(centre + ring(k) * radius + a * pos, n, SIMD2(0, 0))) }
            for k in 0..<sides { addTriangle(c, ids[k], ids[(k + 1) % sides]) }
        }
        addPart(role, from: capStart)
    }

    /// Handle fixed to a face at local y = `faceY`, protruding toward `out` (+1 / -1). `along` is the direction the grip
    /// points (local axis 0 or 2 and its sign). `scale` shrinks the hardware for windows.
    mutating func addHandle(_ l: OpeningDetail.Local, _ kind: OpeningHandle, x: Double, z: Double, faceY: Double, out: Double,
                            along: (axis: Int, sign: Double), scale k: Double, role: MeshRole = .hardware) {
        func yy(_ d: Double) -> Double { faceY + out * d * k }
        func prismY(_ cx: Double, _ cz: Double, r: Double, d0: Double, d1: Double) {
            // Axis y: (u, v) = (z, x).
            let a = faceY + out * d0 * k, b = faceY + out * d1 * k
            addPrism(l, axis: 1, u: cz, v: cx, radius: r * k, from: min(a, b), to: max(a, b), sides: 12, role)
        }
        func gripBox(_ from: Double, _ to: Double, _ d0: Double, _ d1: Double, half: Double) {
            let y0 = yy(d0), y1 = yy(d1)
            if along.axis == 0 {
                let x0 = x + along.sign * from * k, x1 = x + along.sign * to * k
                addBox(l, min(x0, x1), max(x0, x1), min(y0, y1), max(y0, y1), z - half * k, z + half * k, role)
            } else {
                let z0 = z + along.sign * from * k, z1 = z + along.sign * to * k
                addBox(l, x - half * k, x + half * k, min(y0, y1), max(y0, y1), min(z0, z1), max(z0, z1), role)
            }
        }
        switch kind {
        case .none:
            return
        case .lever:
            prismY(x, z, r: 25, d0: 0, d1: 8)
            prismY(x, z, r: 8, d0: 8, d1: 42)
            gripBox(-9, 125, 34, 50, half: 9)
        case .knob:
            prismY(x, z, r: 25, d0: 0, d1: 8)
            prismY(x, z, r: 8, d0: 8, d1: 32)
            prismY(x, z, r: 24, d0: 32, d1: 58)
        case .bar:
            let half = 250.0
            // A vertical pull bar on two posts; it stays vertical for every swing direction.
            for dz in [-half, half] { prismY(x, z + dz * k, r: 8, d0: 0, d1: 40) }
            addPrism(l, axis: 2, u: x, v: yy(46), radius: 12 * k, from: z - (half + 20) * k, to: z + (half + 20) * k, sides: 12, role)
        }
    }
}
