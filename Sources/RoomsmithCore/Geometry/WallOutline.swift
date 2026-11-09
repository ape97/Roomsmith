import Foundation
import simd

/// Derived outline of a wall with mitred joints at shared endpoints.
/// Corner order: startRight, endRight, endLeft, startLeft ("left" = left of start → end).
public struct WallOutline: Sendable, Equatable {
    public var wallId: UUID
    public var startRight: V2
    public var endRight: V2
    public var endLeft: V2
    public var startLeft: V2
    public var polygon: [V2] { [startRight, endRight, endLeft, startLeft] }

    /// Point on the left/right face at a distance `s` (mm) along the axis, clamped to the mitred ends.
    public func facePoint(wall: Wall, s: Double, left: Bool) -> V2 {
        let ax = Geo.axis(wall.start, wall.end)
        let h = Double(wall.thickness) / 2
        if s <= 0 { return left ? startLeft : startRight }
        if s >= ax.length { return left ? endLeft : endRight }
        return wall.start.v + ax.dir * s + ax.normal * (left ? h : -h)
    }

    /// Outlines for all walls of a level (or all walls when levelId is nil).
    public static func compute(_ walls: [Wall], levelId: UUID? = nil) -> [UUID: WallOutline] {
        let list = walls.filter { levelId == nil || $0.levelId == levelId }
        var byPoint: [P2: [Int]] = [:]
        for (i, w) in list.enumerated() {
            byPoint[w.start, default: []].append(i)
            byPoint[w.end, default: []].append(i)
        }
        var result: [UUID: WallOutline] = [:]
        for (i, w) in list.enumerated() {
            let ax = Geo.axis(w.start, w.end)
            let h = Double(w.thickness) / 2
            var sl = w.start.v + ax.normal * h, sr = w.start.v - ax.normal * h
            var el = w.end.v + ax.normal * h, er = w.end.v - ax.normal * h
            if ax.length > 0 {
                if let j = single(byPoint[w.start], except: i) {
                    if let (l, r) = miter(at: w.start, mine: w, myDirOut: -ax.dir, other: list[j]) { sl = r; sr = l }
                }
                if let j = single(byPoint[w.end], except: i) {
                    if let (l, r) = miter(at: w.end, mine: w, myDirOut: ax.dir, other: list[j]) { el = l; er = r }
                }
            }
            result[w.id] = WallOutline(wallId: w.id, startRight: sr, endRight: er, endLeft: el, startLeft: sl)
        }
        return result
    }

    private static func single(_ ids: [Int]?, except i: Int) -> Int? {
        guard let others = ids?.filter({ $0 != i }), others.count == 1 else { return nil }
        return others[0]
    }

    /// Mitre corners at joint point `p`. `myDirOut` points from the wall body out through `p`.
    /// Returns (leftOfOutDir, rightOfOutDir) corners, or nil for (near-)parallel walls / overlong mitres.
    private static func miter(at p: P2, mine: Wall, myDirOut: V2, other: Wall) -> (V2, V2)? {
        let otherFar = other.start == p ? other.end : other.start
        let oax = Geo.axis(p, otherFar)
        guard oax.length > 0 else { return nil }
        let otherDirIn = oax.dir // from p into the other wall's body
        let cross = myDirOut.x * otherDirIn.y - myDirOut.y * otherDirIn.x
        if abs(cross) < 1e-6 { return nil } // collinear continuation or fold-back: square ends
        let myN = V2(-myDirOut.y, myDirOut.x)
        let oN = V2(-otherDirIn.y, otherDirIn.x)
        let hm = Double(mine.thickness) / 2, ho = Double(other.thickness) / 2
        let pv = p.v
        // Following the path mine → other, the left side of `mine` continues as the left side of `other`.
        guard let left = Geo.lineIntersection(pv + myN * hm, myDirOut, pv + oN * ho, otherDirIn),
              let right = Geo.lineIntersection(pv - myN * hm, myDirOut, pv - oN * ho, otherDirIn) else { return nil }
        let limit = 4 * max(hm, ho)
        if simd_length(left - pv) > limit || simd_length(right - pv) > limit { return nil }
        return (left, right)
    }
}
