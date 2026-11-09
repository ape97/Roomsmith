import Foundation

/// Parametric furniture generators for the furniture editor. All results are plain definitions made of primitives.
/// The public generators give every call a fresh definition id (two designs with the same name must not collide);
/// component and state ids derive from the kind and name (key `param.<kind>.<name>`), so regenerating a design keeps
/// instance overrides valid only while name and template stay the same; after a rename or template change
/// `updateDefinition` drops overrides whose component ids no longer exist.
/// The keyed variants used by the built-in catalog are fully deterministic.
public enum ParametricBuilder {
    public static func cabinet(name: String, size: Size3, shelves: Int, doors: Int, plinth: MM, materialId: UUID?) -> FurnitureDefinition {
        fresh(cabinet(key: "param.cabinet.\(name)", name: name, category: "Custom", size: size, shelves: shelves, doors: doors,
                      plinth: plinth, materialId: materialId))
    }

    public static func table(name: String, size: Size3, legInset: MM, topThickness: MM, materialId: UUID?) -> FurnitureDefinition {
        fresh(table(key: "param.table.\(name)", name: name, category: "Custom", size: size, legInset: legInset,
                    topThickness: topThickness, materialId: materialId))
    }

    public static func shelf(name: String, size: Size3, boards: Int, materialId: UUID?) -> FurnitureDefinition {
        fresh(shelf(key: "param.shelf.\(name)", name: name, category: "Custom", size: size, boards: boards, materialId: materialId))
    }

    public static func sofa(name: String, size: Size3, armWidth: MM, seatHeight: MM, materialId: UUID?) -> FurnitureDefinition {
        fresh(sofa(key: "param.sofa.\(name)", name: name, category: "Custom", size: size, armWidth: armWidth, seatHeight: seatHeight,
                   materialId: materialId))
    }

    public static func box(name: String, size: Size3, materialId: UUID?) -> FurnitureDefinition {
        let s = clamped(size)
        var b = PartBuilder(key: "param.box.\(name)", size: s)
        b.put("Body", x: -b.hw ... b.hw, y: -b.hd ... b.hd, z: 0 ... s.height, materialId)
        return fresh(b.finish(name: name, category: "Custom"))
    }

    private static func fresh(_ d: FurnitureDefinition) -> FurnitureDefinition {
        var d = d
        d.id = UUID()
        return d
    }

    // MARK: Keyed variants (used by the built-in catalog so that ids derive from the catalog key)

    static func cabinet(key: String, name: String, category: String, size: Size3, shelves: Int, doors: Int, plinth: MM,
                        materialId: UUID?) -> FurnitureDefinition {
        let s = clamped(size)
        var b = PartBuilder(key: key, size: s)
        cabinetParts(&b, height: s.height, shelves: shelves, doors: doors, plinth: plinth, material: materialId)
        return b.finish(name: name, category: category)
    }

    static func table(key: String, name: String, category: String, size: Size3, legInset: MM, topThickness: MM,
                      materialId: UUID?) -> FurnitureDefinition {
        let s = clamped(size)
        var b = PartBuilder(key: key, size: s)
        let hw = b.hw, hd = b.hd, H = s.height
        let tt = evenClamp(topThickness, 2, max(2, H / 2))
        let lw = evenClamp(60, 2, max(2, min(s.width, s.depth) / 6))
        let inset = max(0, min(legInset, min(hw, hd) - lw - 2))
        b.put("Top", x: -hw ... hw, y: -hd ... hd, z: (H - tt) ... H, materialId)
        let xs: [(String, ClosedRange<MM>)] = [("left", (-hw + inset) ... (-hw + inset + lw)), ("right", (hw - inset - lw) ... (hw - inset))]
        let ys: [(String, ClosedRange<MM>)] = [("front", (-hd + inset) ... (-hd + inset + lw)), ("back", (hd - inset - lw) ... (hd - inset))]
        for (xn, xr) in xs {
            for (yn, yr) in ys { b.put("Leg \(yn) \(xn)", x: xr, y: yr, z: 0 ... (H - tt), materialId) }
        }
        let apron = min(70, H - tt - 10)
        if apron >= 20 {
            let az = (H - tt - apron) ... (H - tt)
            let ax = (-hw + inset + lw) ... (hw - inset - lw)
            let ay = (-hd + inset + lw) ... (hd - inset - lw)
            b.put("Apron front", x: ax, y: (-hd + inset) ... (-hd + inset + 20), z: az, materialId)
            b.put("Apron back", x: ax, y: (hd - inset - 20) ... (hd - inset), z: az, materialId)
            b.put("Apron left", x: (-hw + inset) ... (-hw + inset + 20), y: ay, z: az, materialId)
            b.put("Apron right", x: (hw - inset - 20) ... (hw - inset), y: ay, z: az, materialId)
        }
        return b.finish(name: name, category: category)
    }

    static func shelf(key: String, name: String, category: String, size: Size3, boards: Int, materialId: UUID?) -> FurnitureDefinition {
        let s = clamped(size)
        var b = PartBuilder(key: key, size: s)
        let hw = b.hw, hd = b.hd, H = s.height
        let t = evenClamp(22, 2, max(2, min(s.width, s.height) / 8))
        let back = min(6, max(1, s.depth / 4))
        let n = max(1, min(boards, 60))
        b.put("Side left", x: -hw ... (-hw + t), y: -hd ... hd, z: 0 ... H, materialId)
        b.put("Side right", x: (hw - t) ... hw, y: -hd ... hd, z: 0 ... H, materialId)
        b.put("Back", x: (-hw + t) ... (hw - t), y: (hd - back) ... hd, z: 0 ... H, materialId)
        for i in 0..<n {
            let z0 = n == 1 ? H - t : MM(i) * (H - t) / MM(n - 1)
            b.put("Board \(i + 1)", x: (-hw + t) ... (hw - t), y: -hd ... (hd - back), z: z0 ... (z0 + t), materialId)
        }
        return b.finish(name: name, category: category)
    }

    static func sofa(key: String, name: String, category: String, size: Size3, armWidth: MM, seatHeight: MM,
                     materialId: UUID?) -> FurnitureDefinition {
        let s = clamped(size)
        var b = PartBuilder(key: key, size: s)
        let arm = max(0, min(armWidth, s.width / 4))
        upholsteredParts(&b, armLeft: arm, armRight: arm, seatHeight: seatHeight, material: materialId)
        return b.finish(name: name, category: category)
    }

    // MARK: Shared part generators

    /// Keeps the sizes inside `sizeLimit` (1 mm … 100 m); requested millimetre values are never rounded up.
    static func clamped(_ s: Size3) -> Size3 {
        func c(_ v: MM) -> MM { min(max(v, sizeLimit.lowerBound), sizeLimit.upperBound) }
        return Size3(c(s.width), c(s.depth), c(s.height))
    }

    /// Clamps to [lo, hi] and makes the result even so that half sizes stay whole millimetres.
    static func evenClamp(_ v: MM, _ lo: MM, _ hi: MM) -> MM {
        let c = min(max(v, lo), max(lo, hi))
        return c - c % 2
    }

    /// Carcass with shelves, hinged doors (states closed/open, doors swing 100° around their hinge edge) and an optional plinth.
    /// Fills the width and depth of `b.size`; `height` is the carcass height (a worktop may sit above it).
    static func cabinetParts(_ b: inout PartBuilder, height H: MM, shelves: Int, doors: Int, plinth: MM, material: UUID?) {
        let W = b.size.width, D = b.size.depth
        let hw = b.hw, hd = b.hd
        let t = evenClamp(18, 2, max(2, min(W, D, H) / 8))
        let plinthH = max(0, min(plinth, H / 3))
        let doorCount = max(0, min(doors, max(1, Int(W / 150)), 8))
        let handleDepth: MM = doorCount > 0 ? min(12, max(2, D / 10)) : 0
        let doorT: MM = doorCount > 0 ? evenClamp(18, 2, max(2, D / 8)) : 0
        let front = -hd + handleDepth + doorT
        let back = min(6, t)

        b.put("Side left", x: -hw ... (-hw + t), y: front ... hd, z: plinthH ... H, material)
        b.put("Side right", x: (hw - t) ... hw, y: front ... hd, z: plinthH ... H, material)
        // Between the sides, not over them: overlapping same-direction faces flicker (z-fighting).
        b.put("Top", x: (-hw + t) ... (hw - t), y: front ... hd, z: (H - t) ... H, material)
        b.put("Bottom", x: (-hw + t) ... (hw - t), y: front ... hd, z: plinthH ... (plinthH + t), material)
        b.put("Back", x: (-hw + t) ... (hw - t), y: (hd - back) ... hd, z: (plinthH + t) ... (H - t), material)
        if plinthH > 0 {
            let y0 = min(front + 30, hd - 20 - 2)
            b.put("Plinth", x: (-hw + t) ... (hw - t), y: y0 ... (hd - 20), z: 0 ... plinthH, Palette.blackMetal)
        }
        let n = max(0, min(shelves, 40))
        let zb = plinthH + t, zt = H - t
        for i in 0..<n {
            let zc = zb + (zt - zb) * MM(i + 1) / MM(n + 1)
            b.put("Shelf \(i + 1)", x: (-hw + t) ... (hw - t), y: front ... (hd - back), z: (zc - t / 2) ... (zc + t / 2), material)
        }
        guard doorCount > 0 else { return }
        b.state("closed", asDefault: true)
        b.state("open")
        b.durationMs = 600
        let gap: MM = 3
        let dw = (W - MM(doorCount - 1) * gap) / MM(doorCount)
        let dz = (plinthH + 2) ... (H - 2)
        let zmid = (dz.lowerBound + dz.upperBound) / 2
        let handleHalf = max(2, min(150, (dz.upperBound - dz.lowerBound) / 6))
        let yMid = -hd + handleDepth + doorT / 2
        for i in 0..<doorCount {
            let x0 = -hw + MM(i) * (dw + gap)
            let x1 = i == doorCount - 1 ? hw : x0 + dw
            let hingeLeft = i % 2 == 0
            let pivot = P3(hingeLeft ? x0 : x1, yMid, zmid)
            // Neighbours that share a hinge line swing into the same space when open; one millimetre of height difference keeps
            // their top and bottom faces out of the same plane (no z-fighting where they cross).
            let doorZ = i % 2 == 0 ? dz : (dz.lowerBound + 1) ... (dz.upperBound - 1)
            let door = b.put("Door \(i + 1)", x: x0 ... x1, y: (-hd + handleDepth) ... (-hd + handleDepth + doorT), z: doorZ, material, pivot: pivot)
            let hx = hingeLeft ? (x1 - 34) ... (x1 - 22) : (x0 + 22) ... (x0 + 34)
            let handle = b.put("Handle \(i + 1)", x: hx, y: -hd ... (-hd + handleDepth), z: (zmid - handleHalf) ... (zmid + handleHalf),
                               Palette.chrome, pivot: pivot)
            let swing = R3(0, 0, hingeLeft ? -100 : 100)
            b.pose("open", door, rotation: swing)
            b.pose("open", handle, rotation: swing)
        }
    }

    /// Upholstered seating on short feet: arms (optional per side), back, seat and back cushions.
    static func upholsteredParts(_ b: inout PartBuilder, armLeft: MM, armRight: MM, seatHeight: MM, material: UUID?) {
        let D = b.size.depth, H = b.size.height
        let hw = b.hw, hd = b.hd
        let sh = max(200, min(seatHeight, H - 150))
        let footH = max(20, min(100, sh / 4))
        let cushT = max(20, min(140, (sh - footH) / 2))
        let armTop = min(H, sh + 200)
        let backT = min(220, D / 3)
        let backCushT = min(120, D / 6)
        let cushTop = min(H - 20, sh + 360)

        let fw: MM = 50, inset: MM = 40
        for (xn, xr) in [("left", (-hw + inset) ... (-hw + inset + fw)), ("right", (hw - inset - fw) ... (hw - inset))] {
            for (yn, yr) in [("front", (-hd + inset) ... (-hd + inset + fw)), ("back", (hd - inset - fw) ... (hd - inset))] {
                b.put("Foot \(yn) \(xn)", x: xr, y: yr, z: 0 ... footH, Palette.blackMetal)
            }
        }
        b.put("Base", x: -hw ... hw, y: -hd ... hd, z: footH ... (sh - cushT), material)
        if armLeft > 0 { b.put("Arm left", .cushion, x: -hw ... (-hw + armLeft), y: -hd ... hd, z: footH ... armTop, material) }
        if armRight > 0 { b.put("Arm right", .cushion, x: (hw - armRight) ... hw, y: -hd ... hd, z: footH ... armTop, material) }
        let x0 = -hw + armLeft, x1 = hw - armRight
        b.put("Backrest", .cushion, x: x0 ... x1, y: (hd - backT) ... hd, z: footH ... H, material)
        let inner = x1 - x0
        let seats = max(1, Int((Double(inner) / 600).rounded()))
        let cw = inner / MM(seats)
        for i in 0..<seats {
            let lo = x0 + MM(i) * cw
            let hi = i == seats - 1 ? x1 : lo + cw
            b.put("Seat cushion \(i + 1)", .cushion, x: lo ... hi, y: -hd ... (hd - backT), z: (sh - cushT) ... sh, material)
            b.put("Back cushion \(i + 1)", .cushion, x: lo ... hi, y: (hd - backT - backCushT) ... (hd - backT), z: sh ... cushTop, material)
        }
    }
}

// MARK: Robust ranges

/// Order-insensitive range: a generator never traps with lower > upper, however small the requested size is.
fileprivate func ... (lo: MM, hi: MM) -> ClosedRange<MM> {
    lo <= hi ? ClosedRange(uncheckedBounds: (lo, hi)) : ClosedRange(uncheckedBounds: (hi, lo))
}

fileprivate extension PartBuilder {
    private func fit(_ r: ClosedRange<MM>, _ lo: MM, _ hi: MM) -> ClosedRange<MM> {
        ClosedRange(uncheckedBounds: (Swift.min(Swift.max(r.lowerBound, lo), hi), Swift.min(Swift.max(r.upperBound, lo), hi)))
    }

    /// Like `add`, but keeps the part inside the definition envelope (x/y centred, z from the floor). Parts that collapse to
    /// zero extent keep the 1 mm minimum of `add`.
    @discardableResult
    mutating func put(_ name: String, _ shape: PrimitiveShape = .box, x: ClosedRange<MM>, y: ClosedRange<MM>, z: ClosedRange<MM>,
                      _ material: UUID?, pivot: P3? = nil) -> UUID {
        add(name, shape, x: fit(x, -hw, hw), y: fit(y, -hd, hd), z: fit(z, 0, h), material, pivot: pivot)
    }

    @discardableResult
    mutating func put(_ name: String, _ shape: PrimitiveShape = .box, x: ClosedRange<MM>, y: ClosedRange<MM>, z: ClosedRange<MM>,
                      _ material: Material, pivot: P3? = nil) -> UUID {
        put(name, shape, x: x, y: y, z: z, material.id, pivot: pivot)
    }
}
