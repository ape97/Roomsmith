import SwiftUI
import RoomsmithCore

struct InspectorMultiView: View {
    @Environment(AppModel.self) private var model
    // Raw text: the action buttons parse what is typed right now, so an unconfirmed value is never lost.
    @State private var dxText = "0"
    @State private var dyText = "0"
    @State private var dzText = "0"
    @State private var angleText = "90"

    private enum Edge { case left, right, top, bottom }

    var body: some View {
        let ids = model.selectionIds
        let u = model.unit
        let move = PendingInput.moveDelta(dxText, dyText, dzText, unit: u)
        let angle = PendingInput.angle(angleText)
        Form {
            Section("Selection") {
                LabeledContent("Objects") { Text("\(ids.count)") }
                Button("Group") { model.groupObjects(ids) }
                    .controlSize(.small)
                    .disabled(model.groupableIds(ids).isEmpty)
                    .help("Group the selected furniture")
            }
            Section("Move by") {
                LabeledContent("Δx") { PendingLengthField(title: "Move x", text: $dxText, unit: u) }
                LabeledContent("Δy") { PendingLengthField(title: "Move y", text: $dyText, unit: u) }
                LabeledContent("Δz") { PendingLengthField(title: "Move z", text: $dzText, unit: u) }
                Button("Move") {
                    guard let d = move else { return }
                    if model.perform("Move", { try $0.moveObjects(ids, by: d) }) { dxText = "0"; dyText = "0"; dzText = "0" }
                }
                .controlSize(.small)
                .disabled(move == nil || move == P3.zero)
            }
            Section("Rotate") {
                LabeledContent("Angle") { PendingAngleField(title: "Rotate angle", text: $angleText) }
                Button("Rotate") { if let a = angle { model.rotate(ids, by: a) } }.controlSize(.small).disabled(angle == nil || angle == 0)
            }
            Section("Align") {
                HStack {
                    alignButton("Left", "align.horizontal.left", .left, ids)
                    alignButton("Right", "align.horizontal.right", .right, ids)
                    alignButton("Top", "align.vertical.top", .top, ids)
                    alignButton("Bottom", "align.vertical.bottom", .bottom, ids)
                }
            }
            CollisionSection(ids: ids)
        }
        .formStyle(.grouped)
    }

    private func alignButton(_ title: String, _ icon: String, _ edge: Edge, _ ids: [UUID]) -> some View {
        Button { align(edge, ids) } label: { Label(title, systemImage: icon).labelStyle(.iconOnly) }
            .controlSize(.small)
            .help("Align \(title.lowercased()) edges")
            .disabled(alignTargets(ids).count < 2)
    }

    /// Objects that can be aligned: no members of a selected group, no openings or levels.
    private func alignTargets(_ ids: [UUID]) -> [UUID] {
        let p = model.project
        let selected = Set(ids)
        return ids.filter { id in
            guard let k = p.kind(of: id), k != .opening, k != .level, k != .background else { return false }
            if let g = p.instance(id)?.groupId, selected.contains(g) { return false }
            return true
        }
    }

    private func bounds(_ id: UUID, _ p: Project) -> (lo: P2, hi: P2)? {
        var pts: [P2] = []
        func add(_ i: FurnitureInstance) {
            guard let d = p.definition(i.definitionId) else { pts.append(i.position.xy); return }
            pts += FurnitureResolver.footprint(of: i, definition: d).corners.map { P2(rounding: $0) }
        }
        if let i = p.instance(id) { add(i) }
        else if let g = p.group(id) { for m in g.memberIds { if let i = p.instance(m) { add(i) } } }
        else { pts = p.referencePoints(id) }
        guard let f = pts.first else { return nil }
        var lo = f, hi = f
        for q in pts { lo = P2(min(lo.x, q.x), min(lo.y, q.y)); hi = P2(max(hi.x, q.x), max(hi.y, q.y)) }
        return (lo, hi)
    }

    private func align(_ edge: Edge, _ ids: [UUID]) {
        let targets = alignTargets(ids)
        let p = model.project
        let items = targets.compactMap { id in bounds(id, p).map { (id, $0) } }
        guard items.count >= 2 else { return }
        let target: MM
        switch edge {
        case .left: target = items.map { $0.1.lo.x }.min()!
        case .right: target = items.map { $0.1.hi.x }.max()!
        case .top: target = items.map { $0.1.hi.y }.max()!
        case .bottom: target = items.map { $0.1.lo.y }.min()!
        }
        model.perform("Align") { proj in
            for (id, b) in items {
                let d: P3
                switch edge {
                case .left: d = P3(target - b.lo.x, 0, 0)
                case .right: d = P3(target - b.hi.x, 0, 0)
                case .top: d = P3(0, target - b.hi.y, 0)
                case .bottom: d = P3(0, target - b.lo.y, 0)
                }
                if d.x != 0 || d.y != 0 { try proj.moveObjects([id], by: d) }
            }
        }
    }
}

// MARK: Fields whose text stays with the parent

/// Parsing of text that is still being typed. Action buttons read these directly, because a button click does not
/// move keyboard focus and so would not commit a `CommitField`.
enum PendingInput {
    /// Empty counts as 0. nil when the text is not a length or lies outside `range`.
    static func length(_ text: String, unit: LengthUnit, range: ClosedRange<MM> = -coordinateLimit ... coordinateLimit,
                       emptyIsZero: Bool = true) -> MM? {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return emptyIsZero ? 0 : nil }
        return LengthExpression.parse(t, defaultUnit: unit).flatMap { range.contains($0) ? $0 : nil }
    }

    static func moveDelta(_ x: String, _ y: String, _ z: String, unit: LengthUnit) -> P3? {
        guard let a = length(x, unit: unit), let b = length(y, unit: unit), let c = length(z, unit: unit) else { return nil }
        return P3(a, b, c)
    }

    /// Degrees with one decimal, like `AngleField`.
    static func angle(_ text: String, range: ClosedRange<Double> = -3600 ... 3600) -> Double? {
        let t = text.replacingOccurrences(of: "\u{00B0}", with: "").replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)
        guard let d = Double(t), d.isFinite, range.contains(d) else { return nil }
        return (d * 10).rounded() / 10
    }
}

struct PendingLengthField: View {
    let title: String
    @Binding var text: String
    let unit: LengthUnit
    var range: ClosedRange<MM> = -coordinateLimit ... coordinateLimit
    /// Product dimensions must not be empty; move offsets may.
    var emptyIsZero = true

    var body: some View {
        let invalid = PendingInput.length(text, unit: unit, range: range, emptyIsZero: emptyIsZero) == nil
        HStack(spacing: 4) {
            TextField(title, text: $text)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)
                .foregroundStyle(invalid ? Color.red : Color.primary)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.red, lineWidth: invalid ? 1.5 : 0))
                .accessibilityLabel(title)
                .accessibilityValue(invalid ? "\(text), invalid" : text)
            if invalid {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.caption)
                    .help("Enter a number, for example 2.4 \(unit.rawValue)")
                    .accessibilityLabel("Invalid value for \(title). Enter a number, for example 2.4 \(unit.rawValue)")
            }
            Text(unit.rawValue).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct PendingAngleField: View {
    let title: String
    @Binding var text: String

    var body: some View {
        let invalid = PendingInput.angle(text) == nil
        HStack(spacing: 4) {
            TextField(title, text: $text)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)
                .foregroundStyle(invalid ? Color.red : Color.primary)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.red, lineWidth: invalid ? 1.5 : 0))
                .accessibilityLabel(title)
                .accessibilityValue(invalid ? "\(text), invalid" : text)
            if invalid {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.caption)
                    .help("Enter an angle in degrees, for example 90")
                    .accessibilityLabel("Invalid value for \(title). Enter an angle in degrees, for example 90")
            }
            Text("\u{00B0}").font(.caption).foregroundStyle(.secondary)
        }
    }
}
