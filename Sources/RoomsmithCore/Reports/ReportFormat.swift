import Foundation

/// Locale-independent text helpers shared by the reports: CSV (RFC 4180), Markdown tables and fixed-point numbers
/// (always "." as the decimal separator).
public enum ReportFormat {
    /// One CSV field: quoted when it contains a comma, a double quote, CR or LF; quotes are doubled (RFC 4180).
    /// Text that a spreadsheet would run as a formula (leading `=`, `+`, `-`, `@`, tab or CR) gets a leading `'`,
    /// unless it is a plain number such as "-0.50". Names come from users and agents, so this blocks CSV injection.
    public static func csvField(_ s: String) -> String {
        var s = s
        if let f = s.unicodeScalars.first, "=+-@\t\r".unicodeScalars.contains(f), Double(s) == nil { s = "'" + s }
        guard s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// CSV text: fields joined by commas, records terminated by CRLF (RFC 4180), header first.
    public static func csv(header: [String], rows: [[String]]) -> String {
        ([header] + rows).map { $0.map(csvField).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    /// Markdown cell: backslashes and pipes escaped, line breaks flattened.
    public static func mdCell(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    /// GitHub-style Markdown table. `rightAligned` marks numeric columns.
    public static func markdownTable(header: [String], rows: [[String]], rightAligned: Set<Int> = []) -> String {
        var lines = ["| " + header.map(mdCell).joined(separator: " | ") + " |"]
        lines.append("|" + header.indices.map { rightAligned.contains($0) ? " ---: " : " --- " }.joined(separator: "|") + "|")
        for r in rows { lines.append("| " + r.map(mdCell).joined(separator: " | ") + " |") }
        return lines.joined(separator: "\n") + "\n"
    }

    /// `value` with a fixed number of decimals, "." separator, rounded half away from zero on the *decimal* value.
    /// `String(format:)` alone rounds the binary value (7.525 is stored as 7.52499…, giving "7.52") and rounds exact
    /// binary ties to even; here the value is first printed with 6 extra digits (removing binary noise) and that
    /// decimal text is rounded. Non-finite gives "".
    public static func fixed(_ value: Double, _ places: Int) -> String {
        guard value.isFinite else { return "" }
        let posix = Locale(identifier: "en_US_POSIX")
        guard abs(value) < 1e24 else { return String(format: "%.\(places)f", locale: posix, value) }
        let wide = String(format: "%.\(places + 6)f", locale: posix, abs(value))
        let parts = wide.split(separator: ".", omittingEmptySubsequences: false)
        let whole = parts[0], frac = parts.count > 1 ? parts[1] : ""
        guard var q = Int128(whole + frac.prefix(places)) else { return String(format: "%.\(places)f", locale: posix, value) }
        if let next = frac.dropFirst(places).first, next >= "5" { q += 1 }
        return decimal(q, places: places, negative: value < 0)
    }

    /// `q / 10^places` as text; "-" only when the rounded value is not zero.
    private static func decimal(_ q: Int128, places: Int, negative: Bool) -> String {
        let scale = pow10(places)
        var frac = String(q % scale)
        while frac.count < places { frac = "0" + frac }
        let body = places > 0 ? "\(q / scale).\(frac)" : "\(q / scale)"
        return negative && q != 0 ? "-" + body : body
    }

    /// Exact decimal text of `n / divisor` where divisor is 10^places, rounded half away from zero to `places`.
    /// Used for areas (twice the area in mm² → m²) and prices (minor units) so no Double rounding is involved.
    public static func scaled(_ n: Int128, divisor: Int128, places: Int) -> String {
        // n / divisor with `places` decimals: value = n * 10^places / divisor rounded.
        let negative = n < 0
        let mag = n.magnitude
        let scale = UInt128(pow10(places))
        let d = UInt128(divisor)
        let q = (mag * scale + d / 2) / d
        let whole = q / scale
        var frac = String(q % scale)
        while frac.count < places { frac = "0" + frac }
        let body = places > 0 ? "\(whole).\(frac)" : "\(whole)"
        return negative && q != 0 ? "-" + body : body
    }

    private static func pow10(_ n: Int) -> Int128 { (0..<n).reduce(Int128(1)) { acc, _ in acc * 10 } }

    /// Square metres with 2 decimals from twice the area in mm² (exact, half away from zero).
    public static func squareMetres(twiceAreaMM2: Int64) -> String {
        scaled(Int128(twiceAreaMM2), divisor: 2_000_000, places: 2)
    }

    /// Square metres (2 decimals) from an exact integer area in mm².
    public static func squareMetres(mm2: Int128) -> String { scaled(mm2, divisor: 1_000_000, places: 2) }
    /// Cubic metres (3 decimals) from an exact integer volume in mm³.
    public static func cubicMetres(mm3: Int128) -> String { scaled(mm3, divisor: 1_000_000_000, places: 3) }
    /// Square metres (2 decimals) from an area in mm².
    public static func squareMetres(_ mm2: Double) -> String { fixed(mm2 / 1_000_000, 2) }
    /// Metres (2 decimals) from mm.
    public static func metres(_ mm: Double) -> String { fixed(mm / 1000, 2) }
    /// Cubic metres (3 decimals) from mm³.
    public static func cubicMetres(_ mm3: Double) -> String { fixed(mm3 / 1_000_000_000, 3) }
    /// Price with 2 decimals from minor currency units (cents).
    public static func price(minor: Int64) -> String { scaled(Int128(minor), divisor: 100, places: 2) }
}
