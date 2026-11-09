import Foundation

// Low-level text rules of the Roomsmith Markdown format (see docs/FILE_FORMAT.md).

enum MD {
    // MARK: Escaping

    /// Escapes `\`, `|`, line breaks, the exact text "-" (which means nil) and optionally one extra separator byte.
    static func esc(_ s: String, also extra: UInt8 = 0) -> String {
        if s == "-" { return "\\-" }
        let needs = s.utf8.contains { $0 == 0x5C || $0 == 0x7C || $0 == 0x0A || $0 == 0x0D || (extra != 0 && $0 == extra) }
        guard needs else { return s }
        var out = [UInt8]()
        out.reserveCapacity(s.utf8.count + 8)
        for b in s.utf8 {
            switch b {
            case 0x0A: out.append(0x5C); out.append(0x6E)
            case 0x0D: out.append(0x5C); out.append(0x72)
            case 0x5C, 0x7C: out.append(0x5C); out.append(b)
            default:
                if extra != 0 && b == extra { out.append(0x5C) }
                out.append(b)
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    static func unesc(_ s: String) -> String {
        guard s.utf8.contains(0x5C) else { return s }
        var out = [UInt8]()
        out.reserveCapacity(s.utf8.count)
        var it = s.utf8.makeIterator()
        while let b = it.next() {
            if b == 0x5C, let n = it.next() {
                out.append(n == 0x6E ? 0x0A : n == 0x72 ? 0x0D : n)
            } else {
                out.append(b)
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Splits on `sep` unless escaped with a backslash. Pieces stay raw (escapes kept).
    static func splitRaw(_ s: String, on sep: UInt8) -> [String] {
        var parts = [String]()
        var cur = [UInt8]()
        var escaped = false
        for b in s.utf8 {
            if escaped { cur.append(b); escaped = false }
            else if b == 0x5C { cur.append(b); escaped = true }
            else if b == sep { parts.append(String(decoding: cur, as: UTF8.self)); cur.removeAll(keepingCapacity: true) }
            else { cur.append(b) }
        }
        parts.append(String(decoding: cur, as: UTF8.self))
        return parts
    }

    /// Raw list elements of a `a; b; c` value. Empty value or "-" is the empty list.
    static func splitList(_ raw: String) -> [String] {
        if raw.isEmpty || raw == "-" { return [] }
        var parts = splitRaw(raw, on: 0x3B)
        for i in parts.indices.dropFirst() where parts[i].hasPrefix(" ") { parts[i].removeFirst() }
        return parts
    }

    /// Cells of a table row, raw (escapes kept), with one blank removed on each side. nil if not a row.
    static func splitRow(_ line: String) -> [String]? {
        guard line.utf8.first == 0x7C else { return nil }
        var parts = splitRaw(line, on: 0x7C)
        parts.removeFirst()
        if let last = parts.last, last.allSatisfy({ $0 == " " || $0 == "\t" }) { parts.removeLast() }
        return parts.map { c in
            var s = Substring(c)
            if s.first == " " { s = s.dropFirst() }
            if s.last == " " { s = s.dropLast() }
            return String(s)
        }
    }

    // MARK: Number / value parsing (raw text → value)

    static func trimSpaces(_ s: Substring) -> Substring {
        var t = s
        while t.first == " " { t = t.dropFirst() }
        while t.last == " " { t = t.dropLast() }
        return t
    }

    static func ints(_ s: String, sep: Character, count: Int) -> [Int64]? {
        let parts = s.split(separator: sep, omittingEmptySubsequences: false)
        guard parts.count == count else { return nil }
        var out = [Int64](); out.reserveCapacity(count)
        for p in parts { guard let v = Int64(trimSpaces(p)) else { return nil }; out.append(v) }
        return out
    }

    static func p2(_ s: String) -> P2? { ints(s, sep: ",", count: 2).map { P2($0[0], $0[1]) } }
    static func p3(_ s: String) -> P3? { ints(s, sep: ",", count: 3).map { P3($0[0], $0[1], $0[2]) } }
    static func size(_ s: String) -> Size3? { ints(s, sep: "x", count: 3).map { Size3($0[0], $0[1], $0[2]) } }
    static func r3(_ s: String) -> R3? {
        let parts = s.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 3, let x = Double(trimSpaces(parts[0])), let y = Double(trimSpaces(parts[1])),
              let z = Double(trimSpaces(parts[2])) else { return nil }
        return R3(x, y, z)
    }
    static func bool(_ s: String) -> Bool? {
        switch s { case "yes", "true": true; case "no", "false": false; default: nil }
    }
    static func uuid(_ s: String) -> UUID? { UUID(uuidString: s) }

    // MARK: Formatting (value → raw text)

    static func f(_ v: Bool) -> String { v ? "yes" : "no" }
    static func f(_ v: UUID) -> String { v.uuidString.lowercased() }
    static func f(_ v: UUID?) -> String { v.map { f($0) } ?? "-" }
    static func f(_ v: P2) -> String { "\(v.x),\(v.y)" }
    static func f(_ v: P3) -> String { "\(v.x),\(v.y),\(v.z)" }
    static func f(_ v: Size3) -> String { "\(v.width)x\(v.depth)x\(v.height)" }
    static func f(_ v: R3) -> String { "\(String(describing: v.x)),\(String(describing: v.y)),\(String(describing: v.z))" }
    static func f(_ v: Double) -> String { String(describing: v) }
    static func f(_ v: P3?) -> String { v.map { f($0) } ?? "-" }
    static func f(_ v: Size3?) -> String { v.map { f($0) } ?? "-" }
    static func f(_ v: R3?) -> String { v.map { f($0) } ?? "-" }
    static func f(_ v: P2?) -> String { v.map { f($0) } ?? "-" }
    static func f(_ v: Bool?) -> String { v.map { f($0) } ?? "-" }
    static func f(_ v: Int64?) -> String { v.map { String($0) } ?? "-" }
    static func opt(_ v: String?) -> String { v.map { esc($0) } ?? "-" }
    static func list(_ items: [String]) -> String { items.map { esc($0, also: 0x3B) }.joined(separator: "; ") }
    static func uuids(_ items: [UUID]) -> String { items.map { f($0) }.joined(separator: "; ") }
    static func matMap(_ m: [UUID: UUID]) -> String {
        m.sorted { $0.key.uuidString < $1.key.uuidString }.map { "\(f($0.key))=\(f($0.value))" }.joined(separator: "; ")
    }
    static func matMap(_ m: [UUID: UUID]?) -> String { m.map { matMap($0) } ?? "-" }
}

// MARK: - Parsed document

struct Bullet { var key: String; var raw: String; var line: Int }
struct TRow { var line: Int; var cells: [String] }
struct Table {
    var title: String
    var line: Int
    var columns: [String]
    var index: [String: Int]
    var rows: [TRow]
}

final class Section {
    let name: String
    let line: Int
    var bullets: [Bullet] = []
    var tables: [Table] = []
    var subs: [Section] = []
    init(name: String, line: Int) { self.name = name; self.line = line }
}

struct Doc {
    var front: [Bullet] = []
    var frontLine = 1
    var sections: [Section] = []
}

final class Ctx {
    var warnings: [String] = []
    func warn(_ line: Int, _ message: String) { warnings.append("line \(line): \(message)") }
}

enum MDParser {
    static func lines(of text: String) -> [String] {
        var t = text
        if t.hasPrefix("\u{FEFF}") { t.removeFirst() }
        var out = [String]()
        var start = t.utf8.startIndex
        let u = t.utf8
        var i = start
        while i < u.endIndex {
            if u[i] == 0x0A {
                out.append(String(decoding: u[start..<i], as: UTF8.self))
                start = u.index(after: i)
                i = start
            } else {
                i = u.index(after: i)
            }
        }
        out.append(String(decoding: u[start..<u.endIndex], as: UTF8.self))
        return out.map { $0.utf8.last == 0x0D ? String($0.dropLast()) : $0 }
    }

    static func bullet(_ rest: String, line: Int) -> Bullet? {
        let bytes = Array(rest.utf8)
        var i = 0
        var escaped = false
        while i < bytes.count {
            let b = bytes[i]
            if escaped { escaped = false }
            else if b == 0x5C { escaped = true }
            else if b == 0x3A { break }
            i += 1
        }
        guard i < bytes.count else { return nil }
        let key = MD.unesc(String(decoding: bytes[..<i], as: UTF8.self).trimmingCharacters(in: .whitespaces))
        var v = Substring(String(decoding: bytes[(i + 1)...], as: UTF8.self))
        if v.first == " " { v = v.dropFirst() }
        return Bullet(key: key, raw: String(v), line: line)
    }

    static func isSeparator(_ cells: [String]) -> Bool {
        !cells.isEmpty && cells.allSatisfy { c in
            let t = c.trimmingCharacters(in: .whitespaces)
            return !t.isEmpty && t.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    static func parse(_ text: String, _ ctx: Ctx) throws -> Doc {
        let ls = lines(of: text)
        guard ls.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            throw PersistenceError("missing front matter: the file must start with a line '---'", line: 1)
        }
        var doc = Doc()
        var n = 1
        var closed = false
        while n < ls.count {
            let l = ls[n]
            if l.trimmingCharacters(in: .whitespaces) == "---" { closed = true; n += 1; break }
            if !l.trimmingCharacters(in: .whitespaces).isEmpty {
                if let b = bullet(l, line: n + 1) { doc.front.append(b) }
                else { throw PersistenceError("front matter line is not 'key: value'", line: n + 1) }
            }
            n += 1
        }
        guard closed else { throw PersistenceError("front matter is not closed with '---'", line: ls.last == "" ? ls.count - 1 : ls.count) }

        var top: Section?
        var cur: Section?
        var pendingTitle = ""
        var building: (title: String, line: Int, cols: [String], rows: [TRow], sepSeen: Bool)?

        func flush() {
            guard let b = building else { return }
            building = nil
            var index = [String: Int]()
            for (i, c) in b.cols.enumerated() { index[c] = i }
            let t = Table(title: b.title, line: b.line, columns: b.cols, index: index, rows: b.rows)
            if let cur { cur.tables.append(t) } else { ctx.warn(b.line, "table outside any section ignored") }
            pendingTitle = ""
        }

        while n < ls.count {
            let l = ls[n]
            let lineNo = n + 1
            n += 1
            if l.utf8.first == 0x7C {
                guard let cells = MD.splitRow(l) else { continue }
                if building == nil {
                    building = (pendingTitle, lineNo, cells.map { $0.trimmingCharacters(in: .whitespaces) }, [], false)
                } else if !building!.sepSeen {
                    guard isSeparator(cells) else {
                        throw PersistenceError("table header must be followed by a separator row like |---|---|", line: lineNo)
                    }
                    building!.sepSeen = true
                } else {
                    guard cells.count == building!.cols.count else {
                        throw PersistenceError("table row has \(cells.count) cells, expected \(building!.cols.count)", line: lineNo)
                    }
                    building!.rows.append(TRow(line: lineNo, cells: cells))
                }
                continue
            }
            flush()
            if l.hasPrefix("#### ") {
                pendingTitle = String(l.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            } else if l.hasPrefix("### ") {
                guard let t = top else { throw PersistenceError("'###' block outside of a '##' section", line: lineNo) }
                let s = Section(name: String(l.dropFirst(4)).trimmingCharacters(in: .whitespaces), line: lineNo)
                t.subs.append(s)
                cur = s
                pendingTitle = ""
            } else if l.hasPrefix("## ") {
                let s = Section(name: String(l.dropFirst(3)).trimmingCharacters(in: .whitespaces), line: lineNo)
                doc.sections.append(s)
                top = s; cur = s
                pendingTitle = ""
            } else if l.hasPrefix("- ") {
                guard let cur else { ctx.warn(lineNo, "bullet outside any section ignored"); continue }
                if let b = bullet(String(l.dropFirst(2)), line: lineNo) { cur.bullets.append(b) }
                else { ctx.warn(lineNo, "bullet without 'key: value' ignored") }
            }
            // everything else (title, prose, blank lines) is free text and ignored
        }
        flush()
        return doc
    }
}

// MARK: - Typed access to one table row or one bullet list

struct Rd {
    let cols: [String: Int]
    let cells: [String]
    let line: Int
    let headerLine: Int
    let cellLines: [Int]?

    init(table t: Table, row: TRow) {
        cols = t.index; cells = row.cells; line = row.line; headerLine = t.line; cellLines = nil
    }

    init(bullets: [Bullet], line: Int) {
        var idx = [String: Int]()
        for (i, b) in bullets.enumerated() { idx[b.key] = i }
        cols = idx; cells = bullets.map(\.raw); self.line = bullets.first?.line ?? line; headerLine = line
        cellLines = bullets.map(\.line)
    }

    func lineOf(_ i: Int) -> Int { cellLines?[i] ?? line }
    func has(_ c: String) -> Bool { cols[c] != nil }
    func isNil(_ c: String) -> Bool { cols[c].map { cells[$0] == "-" } ?? true }
    func fail(_ c: String, _ message: String) -> PersistenceError {
        PersistenceError(message, line: cols[c].map(lineOf) ?? line)
    }

    func value<T>(_ c: String, _ def: T?, _ parse: (String) -> T?) throws -> T {
        guard let i = cols[c] else {
            if let def { return def }
            throw PersistenceError("missing column or key '\(c)'", line: headerLine)
        }
        guard let v = parse(cells[i]) else {
            throw PersistenceError("invalid value '\(cells[i])' for '\(c)'", line: lineOf(i))
        }
        return v
    }

    func optional<T>(_ c: String, _ parse: (String) -> T?) throws -> T? {
        guard let i = cols[c], cells[i] != "-" else { return nil }
        guard let v = parse(cells[i]) else {
            throw PersistenceError("invalid value '\(cells[i])' for '\(c)'", line: lineOf(i))
        }
        return v
    }

    func list<T>(_ c: String, _ parse: (String) -> T?) throws -> [T] {
        guard let i = cols[c] else { return [] }
        var out = [T]()
        for part in MD.splitList(cells[i]) {
            guard let v = parse(part) else { throw PersistenceError("invalid list element '\(part)' in '\(c)'", line: lineOf(i)) }
            out.append(v)
        }
        return out
    }

    func str(_ c: String, _ def: String? = nil) throws -> String { try value(c, def) { MD.unesc($0) } }
    func optStr(_ c: String) throws -> String? { try optional(c) { MD.unesc($0) } }
    func uuid(_ c: String) throws -> UUID { try value(c, nil, MD.uuid) }
    func optUUID(_ c: String) throws -> UUID? { try optional(c, MD.uuid) }
    func i64(_ c: String, _ def: Int64? = nil) throws -> Int64 { try value(c, def) { Int64($0) } }
    func optI64(_ c: String) throws -> Int64? { try optional(c) { Int64($0) } }
    func int(_ c: String, _ def: Int) throws -> Int { try value(c, def) { Int($0) } }
    func dbl(_ c: String, _ def: Double? = nil) throws -> Double { try value(c, def) { Double($0) } }
    func bool(_ c: String, _ def: Bool) throws -> Bool { try value(c, def, MD.bool) }
    func optBool(_ c: String) throws -> Bool? { try optional(c, MD.bool) }
    func p2(_ c: String) throws -> P2 { try value(c, nil, MD.p2) }
    func p3(_ c: String) throws -> P3 { try value(c, nil, MD.p3) }
    func size(_ c: String) throws -> Size3 { try value(c, nil, MD.size) }
    func r3(_ c: String, _ def: R3) throws -> R3 { try value(c, def, MD.r3) }
    func optP3(_ c: String) throws -> P3? { try optional(c, MD.p3) }
    func optSize(_ c: String) throws -> Size3? { try optional(c, MD.size) }
    func optR3(_ c: String) throws -> R3? { try optional(c, MD.r3) }
    func color(_ c: String) throws -> RGBColor { try value(c, nil) { RGBColor(hex: $0) } }
    func enumv<T: RawRepresentable>(_ c: String, _ def: T? = nil) throws -> T where T.RawValue == String {
        try value(c, def) { T(rawValue: $0) }
    }
    func uuids(_ c: String) throws -> [UUID] { try list(c, MD.uuid) }
    func strings(_ c: String) throws -> [String] { try list(c) { MD.unesc($0) } }
    func points(_ c: String) throws -> [P2] { try list(c, MD.p2) }

    private static func pairs(_ s: String) -> [UUID: UUID]? {
        var m = [UUID: UUID]()
        for part in MD.splitList(s) {
            let kv = part.split(separator: "=", omittingEmptySubsequences: false)
            guard kv.count == 2, let k = UUID(uuidString: String(MD.trimSpaces(kv[0]))),
                  let v = UUID(uuidString: String(MD.trimSpaces(kv[1]))) else { return nil }
            m[k] = v
        }
        return m
    }
    func matMap(_ c: String) throws -> [UUID: UUID] { try value(c, [:], Rd.pairs) }
    func optMatMap(_ c: String) throws -> [UUID: UUID]? { try optional(c, Rd.pairs) }
}
