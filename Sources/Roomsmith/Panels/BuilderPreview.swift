import simd
import SwiftUI
import RoomsmithCore

/// One resolved component projected into the two preview views (all values in mm).
struct BuilderPart {
    var id: UUID
    var color: Color
    var top: [CGPoint]      // x, y
    var front: [CGPoint]    // x, z
    var roundTop: Bool
    var roundFront: Bool
    var depthKey: Double    // larger = farther from the front viewer (-Y)
    var heightKey: Double
}

enum BuilderProjection {
    static func parts(of def: FurnitureDefinition, stateId: UUID?, materials: [UUID: RoomsmithCore.Material]) -> [BuilderPart] {
        var inst = FurnitureInstance(definitionId: def.id, levelId: UUID(), name: "", position: .zero)
        inst.stateId = stateId
        let corners: [SIMD4<Double>] = (0..<8).map { i in
            SIMD4(i & 1 == 0 ? -0.5 : 0.5, i & 2 == 0 ? -0.5 : 0.5, i & 4 == 0 ? -0.5 : 0.5, 1)
        }
        return FurnitureResolver.resolve(inst, definition: def).compactMap { rc -> BuilderPart? in
            guard rc.visible else { return nil }
            let pts = corners.map { rc.worldMatrix * $0 }
            let m = rc.materialId.flatMap { materials[$0] }
            let col = m.map { Color(red: Double($0.color.r) / 255, green: Double($0.color.g) / 255, blue: Double($0.color.b) / 255) } ?? Color.primary.opacity(0.4)
            let upright = rc.rotation.isZero
            let round = rc.shape == .sphere || rc.shape == .cylinder || rc.shape == .taper
            return BuilderPart(
                id: rc.componentId, color: col,
                top: hull(pts.map { CGPoint(x: $0.x, y: $0.y) }),
                front: hull(pts.map { CGPoint(x: $0.x, y: $0.z) }),
                roundTop: round && upright,
                roundFront: rc.shape == .sphere && upright,
                depthKey: pts.map(\.y).reduce(0, +) / 8,
                heightKey: pts.map(\.z).reduce(0, +) / 8)
        }
    }

    /// Convex hull (monotone chain).
    static func hull(_ pts: [CGPoint]) -> [CGPoint] {
        let p = pts.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        guard p.count > 2 else { return p }
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> Double { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
        var lower: [CGPoint] = [], upper: [CGPoint] = []
        for q in p {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], q) <= 0 { lower.removeLast() }
            lower.append(q)
        }
        for q in p.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], q) <= 0 { upper.removeLast() }
            upper.append(q)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }
}

/// Which side the preview shows.
enum BuilderViewKind { case top, front }

/// Canvas drawing of the components from above (x right, y up) or from the front (x right, z up), with mm dimensions.
struct BuilderCanvas: View {
    let parts: [BuilderPart]
    let kind: BuilderViewKind
    let selected: UUID?

    var body: some View {
        Canvas { ctx, size in draw(&ctx, size) }
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(alignment: .topLeading) {
                Text(kind == .top ? "Top view" : "Front view")
                    .font(.caption).foregroundStyle(.secondary).padding(6)
            }
            .accessibilityLabel(kind == .top ? "Top view preview" : "Front view preview")
    }

    private func outline(_ p: BuilderPart) -> [CGPoint] { kind == .top ? p.top : p.front }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let all = parts.flatMap(outline)
        guard let x0 = all.map(\.x).min(), let x1 = all.map(\.x).max(),
              let v0 = all.map(\.y).min(), let v1 = all.map(\.y).max() else {
            ctx.draw(Text("Nothing visible").foregroundStyle(.secondary), at: CGPoint(x: size.width / 2, y: size.height / 2))
            return
        }
        let pad: CGFloat = 46
        let w = max(x1 - x0, 1), h = max(v1 - v0, 1)
        let s = max(0.0001, min((size.width - 2 * pad) / w, (size.height - 2 * pad) / h))
        let ox = (size.width - w * s) / 2, oy = (size.height + h * s) / 2
        func map(_ p: CGPoint) -> CGPoint { CGPoint(x: ox + (p.x - x0) * s, y: oy - (p.y - v0) * s) }

        // Painter's order: top view low to high; front view far to near.
        let ordered = parts.sorted { kind == .top ? $0.heightKey < $1.heightKey : $0.depthKey > $1.depthKey }
        for part in ordered {
            let pts = outline(part).map(map)
            guard pts.count > 1 else { continue }
            var path = Path()
            let round = kind == .top ? part.roundTop : part.roundFront
            if round, let minX = pts.map(\.x).min(), let maxX = pts.map(\.x).max(), let minY = pts.map(\.y).min(), let maxY = pts.map(\.y).max() {
                path.addEllipse(in: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
            } else {
                path.addLines(pts); path.closeSubpath()
            }
            ctx.fill(path, with: .color(part.color.opacity(0.9)))
            ctx.stroke(path, with: .color(.primary.opacity(0.55)), lineWidth: 0.6)
            if part.id == selected { ctx.stroke(path, with: .color(.orange), lineWidth: 2.2) }
        }

        // Dimensions
        let dim = Color.secondary
        let bl = map(CGPoint(x: x0, y: v0)), br = map(CGPoint(x: x1, y: v0)), tr = map(CGPoint(x: x1, y: v1))
        var line = Path()
        let yb = bl.y + 18
        line.move(to: CGPoint(x: bl.x, y: yb)); line.addLine(to: CGPoint(x: br.x, y: yb))
        line.move(to: CGPoint(x: bl.x, y: yb - 4)); line.addLine(to: CGPoint(x: bl.x, y: yb + 4))
        line.move(to: CGPoint(x: br.x, y: yb - 4)); line.addLine(to: CGPoint(x: br.x, y: yb + 4))
        let xr = br.x + 18
        line.move(to: CGPoint(x: xr, y: br.y)); line.addLine(to: CGPoint(x: xr, y: tr.y))
        line.move(to: CGPoint(x: xr - 4, y: br.y)); line.addLine(to: CGPoint(x: xr + 4, y: br.y))
        line.move(to: CGPoint(x: xr - 4, y: tr.y)); line.addLine(to: CGPoint(x: xr + 4, y: tr.y))
        ctx.stroke(line, with: .color(dim), lineWidth: 0.8)
        ctx.draw(Text("\(Int(w.rounded())) mm").font(.caption2).foregroundStyle(dim), at: CGPoint(x: (bl.x + br.x) / 2, y: yb + 10))
        let vLabel = "\(Int(h.rounded())) mm"
        var vctx = ctx
        vctx.translateBy(x: xr + 10, y: (br.y + tr.y) / 2)
        vctx.rotate(by: .degrees(90))
        vctx.draw(Text(vLabel).font(.caption2).foregroundStyle(dim), at: .zero)
    }
}
