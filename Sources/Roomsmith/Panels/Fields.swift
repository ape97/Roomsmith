import SwiftUI
import RoomsmithCore

/// Parses typed lengths with simple `+` / `−` expressions, e.g. "1234", "123.4 cm", "1.2 m - 20 cm".
/// Bare numbers use `defaultUnit`. Returns nil for anything that is not a whole number of millimetres.
enum LengthExpression {
    static func parse(_ input: String, defaultUnit: LengthUnit) -> MM? {
        let s = input.replacingOccurrences(of: "\u{2212}", with: "-").replacingOccurrences(of: "\u{2013}", with: "-")
        var terms: [String] = []
        var current = ""
        for ch in s {
            if (ch == "+" || ch == "-"), !current.trimmingCharacters(in: .whitespaces).isEmpty {
                terms.append(current)
                current = String(ch)
            } else {
                current.append(ch)
            }
        }
        terms.append(current)
        var total: MM = 0
        for term in terms {
            guard let v = LengthUnit.parse(term, defaultUnit: defaultUnit) else { return nil }
            let (sum, overflow) = total.addingReportingOverflow(v)
            if overflow { return nil }
            total = sum
        }
        return abs(total) <= coordinateLimit ? total : nil
    }
}

/// Unit label next to a field ("cm", "°"): one style and a common column width, so the fields of different rows line up.
struct UnitSuffix: View {
    let text: String
    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
            .frame(minWidth: 18, alignment: .leading)
            .accessibilityHidden(true)
    }
}

/// A text field that shows a value, commits on Enter or focus loss, and turns red when the input is invalid
/// or the command fails. Esc or focus loss with invalid input restores the stored value.
struct CommitField<Value: Equatable>: View {
    let title: String
    let value: Value
    let format: (Value) -> String
    let parse: (String) -> Value?
    /// Applies the new value; returns false if the command failed.
    let onCommit: (Value) -> Bool
    var suffix: String?
    var alignment: TextAlignment = .trailing

    @State private var text = ""
    @State private var invalid = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            TextField(title, text: $text)
                .labelsHidden()
                .multilineTextAlignment(alignment)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .foregroundStyle(invalid ? Color.red : Color.primary)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.red, lineWidth: invalid ? 1.5 : 0))
                .onSubmit { commit(blur: false) }
                .onExitCommand { text = format(value); invalid = false }
                .accessibilityLabel(title)
                .accessibilityValue(invalid ? "\(text), invalid" : text)
                .help(invalid ? "Not a valid value. Check the number and unit, then press Return. Esc restores the old value." : "")
            if invalid {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.caption)
                    .help("Not a valid value. Check the number and unit, then press Return. Esc restores the old value.")
                    .accessibilityLabel("Invalid value for \(title)")
            }
            if let suffix { UnitSuffix(text: suffix) }
        }
        .onAppear { text = format(value) }
        .onChange(of: value) { _, new in if !focused { text = format(new); invalid = false } }
        .onChange(of: focused) { _, now in if !now { commit(blur: true) } }
    }

    private func commit(blur: Bool) {
        if text == format(value) { invalid = false; return }
        guard let new = parse(text) else {
            if blur { text = format(value); invalid = false } else { invalid = true }
            return
        }
        if new == value { text = format(value); invalid = false; return }
        if onCommit(new) {
            invalid = false
            text = format(new)
        } else if blur {
            text = format(value); invalid = false
        } else {
            invalid = true
        }
    }
}

/// Length in the project's display unit; stores exact mm.
struct LengthField: View {
    let title: String
    let value: MM
    let unit: LengthUnit
    var range: ClosedRange<MM> = -coordinateLimit ... coordinateLimit
    /// Hides the unit label (for rows with several fields).
    var compact = false
    let onCommit: (MM) -> Bool

    var body: some View {
        CommitField(title: title, value: value,
                    format: { unit.format($0, withUnit: false) },
                    parse: { s in LengthExpression.parse(s, defaultUnit: unit).flatMap { range.contains($0) ? $0 : nil } },
                    onCommit: onCommit, suffix: compact ? nil : unit.rawValue)
    }
}

/// Angle in degrees with one decimal; the document keeps 0.001 degree resolution.
struct AngleField: View {
    let title: String
    let value: Double
    /// Values must lie in this range (default: any finite angle; commands normalise).
    var range: ClosedRange<Double> = -3600 ... 3600
    let onCommit: (Double) -> Bool

    var body: some View {
        CommitField(title: title, value: value,
                    format: { String(format: "%.1f", $0) },
                    parse: { s in
                        let t = s.replacingOccurrences(of: "\u{00B0}", with: "").replacingOccurrences(of: ",", with: ".")
                            .trimmingCharacters(in: .whitespaces)
                        guard let d = Double(t), d.isFinite, range.contains(d) else { return nil }
                        return (d * 10).rounded() / 10
                    },
                    onCommit: onCommit, suffix: "\u{00B0}")
    }
}

/// Single-line text (names). Empty input is invalid unless `allowEmpty`.
struct NameField: View {
    let title: String
    let value: String
    var allowEmpty = false
    let onCommit: (String) -> Bool

    var body: some View {
        CommitField(title: title, value: value, format: { $0 },
                    parse: { s in
                        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                        return t.isEmpty && !allowEmpty ? nil : t
                    },
                    onCommit: onCommit, alignment: .leading)
    }
}

/// Plain decimal number (e.g. a price in major units).
struct DecimalText {
    /// "129.90" → 12990 minor units; at most two decimals.
    static func parseMinor(_ s: String) -> Int64? {
        let t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard t.wholeMatch(of: /\d+(\.\d{1,2})?/) != nil, let d = Decimal(string: t, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        let minor = NSDecimalNumber(decimal: d * 100)
        guard minor.doubleValue < 1e15 else { return nil }
        return minor.int64Value
    }

    static func formatMinor(_ minor: Int64) -> String {
        let sign = minor < 0 ? "-" : ""
        let m = minor.magnitude
        return "\(sign)\(m / 100).\(String(format: "%02d", Int(m % 100)))"
    }
}

/// Material choice with a swatch; `nil` is the default entry.
struct MaterialPicker: View {
    let title: String
    let materials: [RoomsmithCore.Material]
    let selection: UUID?
    var defaultLabel = "Default"
    /// Name above a full-width menu, so long material names stay readable in the narrow inspector.
    var stacked = false
    let onChange: (UUID?) -> Void

    var body: some View {
        if stacked {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                picker.labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            picker
        }
    }

    private var picker: some View {
        Picker(title, selection: Binding(get: { selection }, set: { onChange($0) })) {
            Text(defaultLabel).tag(UUID?.none)
            Divider()
            ForEach(materials) { m in
                Label {
                    Text(m.name)
                } icon: {
                    Image(systemName: "circle.fill").foregroundStyle(Color(red: Double(m.color.r) / 255, green: Double(m.color.g) / 255, blue: Double(m.color.b) / 255))
                }
                .tag(UUID?.some(m.id))
            }
        }
    }
}

extension LengthUnit {
    func formatted(_ mm: MM) -> String { format(mm) }
    /// Area in m² for display.
    static func areaText(_ mm2: Double) -> String { String(format: "%.2f m\u{00B2}", mm2 / 1_000_000) }
}

/// Two length fields for a point, with a row label.
struct PointFields: View {
    let title: String
    let point: P2
    let unit: LengthUnit
    let onCommit: (P2) -> Bool

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                LengthField(title: "\(title) x", value: point.x, unit: unit, compact: true) { onCommit(P2($0, point.y)) }
                LengthField(title: "\(title) y", value: point.y, unit: unit, compact: true) { onCommit(P2(point.x, $0)) }
                UnitSuffix(text: unit.rawValue)
            }
        }
    }
}
