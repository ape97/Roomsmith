import Foundation

/// Text-level migrations of `project.md`, applied before decoding.
///
/// The migration is a chain of single steps (1 → 2 → 3 → 4 → 5), each stamping only its own target schema.
///
/// Schema 1 → 2: the Openings column `elevation` was renamed `sill`, and the `## Settings` section was added
/// (appended with defaults at the end, so line numbers of existing content stay stable).
///
/// Schema 2 → 3: additive only (lighting keys, opening/material columns, `#### Lights`, `lightOn`); only the stamp changes.
///
/// Schema 3 → 4: additive only (camera mode `free`); only the stamp changes.
///
/// Schema 4 → 5: additive only (furniture options: `#### Options` table per definition, Instances column `options`);
/// only the stamp changes.
public enum ProjectMigration {
    public static func migrate(_ text: String) throws -> (text: String, notes: [String]) {
        var lines = MDParser.lines(of: text)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            throw PersistenceError("missing front matter: the file must start with a line '---'", line: 1)
        }
        var schemaLine: Int?
        var end: Int?
        for i in 1..<lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t == "---" { end = i; break }
            if t.hasPrefix("schema:") { schemaLine = i }
        }
        guard end != nil else { throw PersistenceError("front matter is not closed with '---'", line: lines.last == "" ? lines.count - 1 : lines.count) }
        guard let sl = schemaLine else { throw PersistenceError("front matter has no 'schema:' entry", line: 1) }
        let value = lines[sl].dropFirst("schema:".count).trimmingCharacters(in: .whitespaces)
        guard let schema = Int(value) else { throw PersistenceError("invalid schema '\(value)'", line: sl + 1) }
        if schema == Project.currentSchemaVersion { return (text, []) }
        guard (1..<Project.currentSchemaVersion).contains(schema) else {
            let why = schema > Project.currentSchemaVersion ? "written by a newer Roomsmith version" : "unknown"
            throw PersistenceError("unsupported schema \(schema) (\(why))", line: sl + 1)
        }

        var notes: [String] = []
        if schema == 1 { migrateV1ToV2(&lines, schemaLine: sl, notes: &notes) }
        // Schema 2 → 3, 3 → 4 and 4 → 5: additive only, each stamps its target schema. A future bump adds its own step after these.
        if schema < 3 {
            notes.append("schema 2 → 3")
            lines[sl] = "schema: 3"
        }
        if schema < 4 {
            notes.append("schema 3 → 4")
            lines[sl] = "schema: 4"
        }
        if schema < 5 {
            notes.append("schema 4 → 5")
            lines[sl] = "schema: 5"
        }
        return (lines.joined(separator: "\n"), notes)
    }

    private static func migrateV1ToV2(_ lines: inout [String], schemaLine sl: Int, notes: inout [String]) {
        notes.append("schema 1 → 2")
        lines[sl] = "schema: 2"
        if let o = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).lowercased() == "## openings" }),
           let h = lines[(o + 1)...].prefix(while: { !$0.hasPrefix("## ") }).firstIndex(where: { $0.utf8.first == 0x7C }) {
            var cells = lines[h].components(separatedBy: "|")
            if let c = cells.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "elevation" }) {
                cells[c] = " sill "
                lines[h] = cells.joined(separator: "|")
                notes.append("Openings column 'elevation' renamed to 'sill'")
            }
        }
        if !lines.contains(where: { $0.trimmingCharacters(in: .whitespaces).lowercased() == "## settings" }) {
            while lines.last?.isEmpty == true { lines.removeLast() }
            lines.append("")
            lines += RoomsmithMarkdown.settingsBlock(ProjectSettings()).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            notes.append("added '## Settings' with default values")
        }
    }
}
