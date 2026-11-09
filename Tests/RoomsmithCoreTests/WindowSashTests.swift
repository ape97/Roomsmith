import Foundation
import simd
import Testing
@testable import RoomsmithCore

// Contract tests of the openable window profile. Expected values come from the geometric contract (a sash of width w and
// depth 2 ds needs sqrt(w^2 + 4 ds^2) - w of room at its free edge, a tilted one needs the same at the top), not from the code.

private let lvl = UUID()
private let thicknesses: [MM] = [24, 50, 64, 80]
private func halfDepth(_ t: MM) -> Double { max(min(Double(t) / 2, 40) - 8, 4) }
private func need(_ l: Double, _ ds: Double) -> Double { (l * l + 4 * ds * ds).squareRoot() - l }

private func wallX(_ thickness: MM) -> Wall { Wall(levelId: lvl, start: P2(0, 0), end: P2(6000, 0), thickness: thickness, height: 2600) }

private func window(_ w: Wall, style: OpeningStyle, width: MM = 1400, height: MM = 1300, sill: MM = 900, flipped: Bool = false,
                    inward: Bool = true, kind: OpeningKind = .window, handle: OpeningHandle = .lever) -> Opening {
    var o = Opening(wallId: w.id, kind: kind, offset: 3000, width: width, height: height, sill: sill)
    o.style = style; o.flipped = flipped; o.inward = inward; o.handle = handle
    return o
}

struct WindowProfileContractTests {
    @Test func freeClearanceCoversTheSweptCorner() {
        for ds in [4.0, 17, 24, 32] {
            for l in stride(from: 100.0, through: 3000, by: 1) { #expect(WindowProfile.freeClearance(l, ds: ds) >= need(l, ds)) }
        }
    }

    @Test func singleSashWidthKeepsItsClearance() {
        for ds in [4.0, 17, 24, 32] {
            for iw in stride(from: 200.0, through: 3000, by: 1) {
                let m = WindowProfile.effectiveMotion(style: .tiltTurn1, innerWidth: iw, innerHeight: 1200, ds: ds)
                guard m.movable else { continue }
                #expect(m.sashCount == 1)
                #expect(m.sashWidth >= WindowProfile.minSashWidth)
                #expect(iw - m.sashWidth >= need(m.sashWidth, ds), "iw \(iw) ds \(ds)")
            }
        }
    }

    @Test func twoSashWidthKeepsItsClearance() {
        for ds in [4.0, 17, 24, 32] {
            for iw in stride(from: 400.0, through: 3000, by: 1) {
                let m = WindowProfile.effectiveMotion(style: .tiltTurn2, innerWidth: iw, innerHeight: 1200, ds: ds)
                guard m.movable, m.sashCount == 2 else { continue }
                #expect(iw / 2 - m.sashWidth >= need(m.sashWidth, ds), "iw \(iw) ds \(ds)")
            }
        }
    }

    @Test func heightKeepsItsClearance() {
        for ds in [4.0, 17, 24, 32] {
            for ih in stride(from: 300.0, through: 3000, by: 1) {
                let m = WindowProfile.effectiveMotion(style: .tiltTurn1, innerWidth: 900, innerHeight: ih, ds: ds)
                guard m.movable else { continue }
                #expect(ih - m.sashHeight >= need(m.sashHeight, ds), "ih \(ih) ds \(ds)")
                #expect(m.sashHeight >= WindowProfile.minSashHeight)
            }
        }
    }

    @Test func thresholdsAreSharpAroundTheMinimumSizes() {
        for ds in [4.0, 17, 24, 32] {
            // Width: the smallest movable inner width produces a sash of at least the minimum; one millimetre less is fixed.
            let widths = stride(from: 1.0, through: 600, by: 1).map {
                WindowProfile.effectiveMotion(style: .tiltTurn1, innerWidth: $0, innerHeight: 1200, ds: ds)
            }
            let first = widths.firstIndex { $0.movable }!
            #expect(widths[first].sashWidth >= WindowProfile.minSashWidth)
            #expect(!widths[first - 1].movable)
            #expect(widths[first...].allSatisfy { $0.movable }, "movable stays movable when wider")
            let heights = stride(from: 1.0, through: 600, by: 1).map {
                WindowProfile.effectiveMotion(style: .tiltTurn1, innerWidth: 900, innerHeight: $0, ds: ds)
            }
            let firstH = heights.firstIndex { $0.movable }!
            #expect(heights[firstH].sashHeight >= WindowProfile.minSashHeight)
            #expect(!heights[firstH - 1].movable)
        }
    }

    @Test func fixedAndTooSmallStylesNeverMove() {
        for s in [OpeningStyle.fixed, .smooth, .glass, .sliding] {
            #expect(!WindowProfile.effectiveMotion(style: s, innerWidth: 1500, innerHeight: 1200, ds: 17).movable)
        }
        #expect(!WindowProfile.effectiveMotion(style: .tiltTurn1, innerWidth: 150, innerHeight: 1200, ds: 17).movable)
        #expect(!WindowProfile.effectiveMotion(style: .tiltTurn1, innerWidth: 900, innerHeight: 250, ds: 17).movable)
    }

    @Test func twoSashStylesFallBackToOneWhenTooNarrow() {
        for ds in [4.0, 17, 24, 32] {
            let wide = WindowProfile.effectiveMotion(style: .tiltTurn2, innerWidth: 1050, innerHeight: 1200, ds: ds)
            #expect(wide.sashCount == 2)
            let narrow = WindowProfile.effectiveMotion(style: .balconyDoor2, innerWidth: 330, innerHeight: 1200, ds: ds)
            #expect(narrow.sashCount == 1 && narrow.movable)
            let tiny = WindowProfile.effectiveMotion(style: .balconyDoor2, innerWidth: 150, innerHeight: 1200, ds: ds)
            #expect(!tiny.movable && tiny.sashCount == 0)
        }
    }
}

struct WindowSashGeometryTests {
    private func sashes(_ w: Wall, _ o: Opening) -> [Meshes.WindowSash] { Meshes.windowSashes(o, wall: w, baseZ: 0) }

    private func bodyPoints(_ s: Meshes.WindowSash, turn: Double = 0, tilt: Double = 0, hardware: Bool = false) -> [SIMD3<Double>] {
        var out: [SIMD3<Double>] = []
        for part in s.mesh.parts where hardware || part.role != .windowHardware {
            for i in part.indexRange { out.append(s.placement.world(s.mesh.positions[Int(s.mesh.indices[i])], turn: turn, tilt: tilt)) }
        }
        return out
    }

    @Test func countsFollowTheStyle() {
        let w = wallX(100)
        #expect(sashes(w, window(w, style: .fixed)).isEmpty)
        #expect(sashes(w, window(w, style: .tiltTurn1)).count == 1)
        #expect(sashes(w, window(w, style: .tiltTurn2)).count == 2)
        #expect(sashes(w, window(w, style: .balconyDoor2, width: 1800, height: 2100, sill: 0)).count == 2)
        #expect(sashes(w, window(w, style: .tiltTurn1, width: 250)).isEmpty, "too small stays fixed")
        #expect(sashes(w, window(w, style: .tiltTurn1, kind: .door)).isEmpty)
    }

    @Test func closedSashesPlusFrameEqualTheClosedMesh() {
        for t in thicknesses {
            let w = wallX(t)
            for style in [OpeningStyle.tiltTurn1, .tiltTurn2, .balconyDoor, .balconyDoor2] {
                let o = window(w, style: style, width: 1600, height: 1600, sill: 600)
                let full = Meshes.openingFrame(o, wall: w, baseZ: 0)
                let frame = Meshes.openingFrame(o, wall: w, baseZ: 0, includeSashes: false)
                let parts = sashes(w, o)
                #expect(!parts.isEmpty)
                #expect(frame.indices.count + parts.reduce(0) { $0 + $1.mesh.indices.count } == full.indices.count, "\(style) \(t)")
                func ext(_ m: MeshData, _ k: (SIMD3<Double>) -> Double) -> [Double] { [m.positions.map(k).min() ?? 0, m.positions.map(k).max() ?? 0] }
                // Hardware (handle, hinges) may stand proud of the frame depth, so only the opening plane is compared.
                for k in [{ (p: SIMD3<Double>) in p.x }, { $0.z }] { #expect(ext(frame, k) == ext(full, k)) }
            }
        }
    }

    @Test func frameFitsTheOpeningAtEveryThickness() {
        for t in thicknesses {
            let w = wallX(t)
            let o = window(w, style: .tiltTurn2, width: 1400, height: 1200)
            let m = Meshes.openingFrame(o, wall: w, baseZ: 0)
            for part in m.parts {
              for i in part.indexRange {
                let p = m.positions[Int(m.indices[i])]
                #expect(p.x >= 2300 - 1e-6 && p.x <= 3700 + 1e-6 && p.z >= 900 - 1e-6 && p.z <= 2100 + 1e-6)
                if part.role == .windowHardware { continue }
                #expect(abs(p.y) <= min(Double(t) / 2, 40) + 1e-6, "frame depth is capped at maxFrameHalfDepth")
              }
            }
        }
    }

    @Test func turnedFreeEdgeIsOneSashWidthAwayOnTheSwingSide() {
        for t in thicknesses {
            for inward in [true, false] {
                for flipped in [false, true] {
                    let w = wallX(t)
                    let o = window(w, style: .tiltTurn2, width: 1800, flipped: flipped, inward: inward)
                    let face: Double = inward ? 1 : -1
                    for s in sashes(w, o) {
                        let pts = bodyPoints(s, turn: 1)
                        // Distance along the swing direction (the wall normal times face) from the pivot plane.
                        let reach = pts.map { ($0.y - s.placement.pivot.y) * face }.max()!
                        #expect(abs(reach - s.placement.width) <= 1, "t \(t) inward \(inward) flipped \(flipped)")
                        // The hinge edge stays on the wall line.
                        #expect(pts.map { abs($0.x - s.placement.pivot.x) }.min()! <= 1)
                    }
                }
            }
        }
    }

    @Test func tiltMovesTheTopAndKeepsTheBottom() {
        for t in thicknesses {
            for inward in [true, false] {
                let w = wallX(t)
                let o = window(w, style: .tiltTurn1, inward: inward)
                let face: Double = inward ? 1 : -1
                let s = sashes(w, o)[0]
                let closed = bodyPoints(s), tilted = bodyPoints(s, tilt: 1)
                let h = s.placement.height
                var topShift = 0.0
                for (a, b) in zip(closed, tilted) {
                    if a.z - s.placement.pivot.z < 1 && abs(a.y - s.placement.pivot.y) < 1 { #expect(length(a - b) <= 1.5, "the pivot line stays") }
                    if abs(a.z - s.placement.pivot.z - h) < 1 { topShift = max(topShift, (b.y - a.y) * face) }
                }
                #expect(abs(topShift - h * sin(10 * .pi / 180)) <= 1.5, "t \(t) inward \(inward)")
            }
        }
    }

    /// The frame as the 8 boxes the contract lists (wall-local, wall along x from the origin): x0, x1, y0, y1, z0, z1.
    private func frameBoxes(_ w: Wall, _ o: Opening) -> [(Double, Double, Double, Double, Double, Double)] {
        let info = Meshes.windowInfo(o, wall: w)!
        let d = min(Double(w.thickness) / 2, WindowProfile.maxFrameHalfDepth)
        let s0 = info.cut.s0, s1 = info.cut.s1, z0 = info.cut.z0, z1 = info.cut.z1, ft = info.ft
        let rb = min(WindowProfile.rebateWidth, ft / 2), step = min(WindowProfile.rebateStep, d / 2)
        return [(s0, s0 + ft - rb, -d, d, z0 + ft, z1 - ft), (s0 + ft - rb, s0 + ft, -d + step, d - step, z0 + ft, z1 - ft),
                (s1 - ft + rb, s1, -d, d, z0 + ft, z1 - ft), (s1 - ft, s1 - ft + rb, -d + step, d - step, z0 + ft, z1 - ft),
                (s0, s1, -d, d, z0, z0 + ft - rb), (s0 + ft, s1 - ft, -d + step, d - step, z0 + ft - rb, z0 + ft),
                (s0, s1, -d, d, z1 - ft + rb, z1), (s0 + ft, s1 - ft, -d + step, d - step, z1 - ft, z1 - ft + rb)]
    }

    @Test func movingSashesNeverEnterTheFrame() {
        let samples = [0.05, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0]
        let sizes: [(MM, MM)] = [(450, 400), (700, 1300), (1400, 1300), (2000, 2200), (2400, 1000)]
        for t in thicknesses {
            let w = wallX(t)
            for style in [OpeningStyle.tiltTurn1, .tiltTurn2, .balconyDoor, .balconyDoor2] {
                for (width, height) in sizes {
                    for flipped in [false, true] {
                        for inward in [true, false] {
                            let o = window(w, style: style, width: width, height: height, sill: 300, flipped: flipped, inward: inward)
                            let boxes = frameBoxes(w, o)
                            for s in sashes(w, o) {
                                for e in samples {
                                    for (turn, tilt) in [(e, 0.0), (0.0, s.placement.hasHandle ? e : 0)] {
                                        for p in bodyPoints(s, turn: turn, tilt: tilt, hardware: true) {
                                            for b in boxes {
                                                let inside = p.x > b.0 + 1 && p.x < b.1 - 1 && p.y > b.2 + 1 && p.y < b.3 - 1 && p.z > b.4 + 1 && p.z < b.5 - 1
                                                #expect(!inside, "\(style) \(width)x\(height) t \(t) e \(e) turn \(turn) tilt \(tilt) at \(p)")
                                                if inside { return }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @Test func twoTurnedSashesDoNotTouch() {
        for t in thicknesses {
            for style in [OpeningStyle.tiltTurn2, .balconyDoor2] {
                let w = wallX(t)
                let o = window(w, style: style, width: 1800, height: 1600, sill: 300)
                let two = sashes(w, o)
                #expect(two.count == 2)
                func box(_ s: Meshes.WindowSash) -> (SIMD3<Double>, SIMD3<Double>) {
                    let p = bodyPoints(s, turn: 1)
                    return (SIMD3(p.map(\.x).min()!, p.map(\.y).min()!, p.map(\.z).min()!), SIMD3(p.map(\.x).max()!, p.map(\.y).max()!, p.map(\.z).max()!))
                }
                let a = box(two[0]), b = box(two[1])
                let apart = a.1.x < b.0.x || b.1.x < a.0.x || a.1.y < b.0.y || b.1.y < a.0.y
                #expect(apart, "\(style) \(t)")
            }
        }
    }

    @Test func handleSitsOnTheRightSash() {
        let w = wallX(100)
        for flipped in [false, true] {
            let two = sashes(w, window(w, style: .tiltTurn2, width: 1800, flipped: flipped))
            #expect(two.count == 2)
            let withHandle = two.filter(\.placement.hasHandle)
            #expect(withHandle.count == 1)
            #expect(withHandle[0].placement.index == (flipped ? 1 : 0))
            for s in two {
                let hw = s.mesh.parts.contains { $0.role == .windowHardware }
                #expect(hw == s.placement.hasHandle)
            }
        }
        let none = sashes(w, window(w, style: .tiltTurn1, handle: .none))
        #expect(none[0].mesh.parts.allSatisfy { $0.role != .windowHardware })
    }

    @Test func hingesStayInTheFrameMesh() {
        let w = wallX(100)
        let o = window(w, style: .tiltTurn1)
        let frame = Meshes.openingFrame(o, wall: w, baseZ: 0, includeSashes: false)
        #expect(frame.parts.contains { $0.role == .windowHardware })
    }

    @Test func balconyDoorHasAHigherBottomRailAndADoorHandleHeight() {
        let w = wallX(100)
        let o = window(w, style: .balconyDoor, width: 1000, height: 2200, sill: 0)
        let s = sashes(w, o)[0]
        let hw = bodyPoints(s, hardware: true).filter { _ in true }
        let handleZ = s.mesh.parts.filter { $0.role == .windowHardware }.flatMap { part in
            part.indexRange.map { s.mesh.positions[Int(s.mesh.indices[$0])].z }
        }
        #expect(!hw.isEmpty && !handleZ.isEmpty)
        #expect(handleZ.reduce(0, +) / Double(handleZ.count) > 800, "handle at door height, not mid sash only")
    }
}
