import AppKit
import RoomsmithCore
import SwiftUI
import UniformTypeIdentifiers

/// The reports the sheet can write. Each is available as CSV or Markdown.
enum ReportKind: String, CaseIterable, Identifiable {
    case room, bom, clearance
    var id: String { rawValue }
    var title: String {
        switch self { case .room: "Room report"; case .bom: "Bill of materials"; case .clearance: "Clearance check" }
    }
    var symbol: String {
        switch self { case .room: "square.dashed"; case .bom: "list.bullet.rectangle"; case .clearance: "arrow.left.and.right" }
    }
    var fileSuffix: String {
        switch self { case .room: "rooms"; case .bom: "bom"; case .clearance: "clearance" }
    }
}

enum ReportFileFormat: String, CaseIterable, Identifiable {
    case csv, markdown
    var id: String { rawValue }
    var title: String { self == .csv ? "CSV" : "Markdown" }
    var fileExtension: String { self == .csv ? "csv" : "md" }
    var contentType: UTType { self == .csv ? .commaSeparatedText : (UTType(filenameExtension: "md") ?? .plainText) }
}

/// Builds the report text. The clearance table comes from `ReportTools` (the agent tool's header and rows).
enum ReportBuilder {
    static func text(_ kind: ReportKind, _ format: ReportFileFormat, project p: Project) -> String {
        switch (kind, format) {
        case (.room, .csv): return RoomReport.make(p).csv()
        case (.room, .markdown): return RoomReport.make(p).markdown()
        case (.bom, .csv): return BillOfMaterials.make(p).csv()
        case (.bom, .markdown): return BillOfMaterials.make(p).markdown()
        case (.clearance, _):
            let list = ClearanceCheck.run(p)
            if format == .csv { return ReportFormat.csv(header: ReportTools.clearanceHeader, rows: ReportTools.clearanceRows(list, p)) }
            return "# Clearance check: \(ReportFormat.mdCell(p.name))\n\n"
                + (list.isEmpty ? "No findings.\n"
                   : ReportFormat.markdownTable(header: ReportTools.clearanceHeader, rows: ReportTools.clearanceRows(list, p), rightAligned: [5, 6, 8, 9]))
        }
    }
}

/// File > Export > Reports…: pick report and format, then save through the save panel.
/// Under test mode the file goes to `ROOMSMITH_EXPORT_DIR` instead (no panel).
struct ReportsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var formats: [ReportKind: ReportFileFormat] = [.room: .csv, .bom: .csv, .clearance: .csv]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Reports").font(.title2.weight(.semibold))
            Text("Save a table of the whole project as CSV or Markdown.")
                .foregroundStyle(.secondary)
            VStack(spacing: 10) {
                ForEach(ReportKind.allCases) { kind in
                    HStack(spacing: 12) {
                        Image(systemName: kind.symbol).frame(width: 22).foregroundStyle(.secondary)
                        Text(kind.title)
                        Spacer()
                        Picker("Format", selection: Binding(get: { formats[kind] ?? .csv }, set: { formats[kind] = $0 })) {
                            ForEach(ReportFileFormat.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden().pickerStyle(.segmented).frame(width: 150)
                        Button("Save…") { save(kind) }
                    }
                }
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func save(_ kind: ReportKind) {
        let format = formats[kind] ?? .csv
        let project = model.project
        let base = model.fileURL?.deletingPathExtension().lastPathComponent ?? project.name
        let name = "\(base)-\(kind.fileSuffix).\(format.fileExtension)"
        guard let url = ExportActions.destination(name: name, type: format.contentType, message: "Save \(kind.title.lowercased())", model: model) else { return }
        do {
            try Data(ReportBuilder.text(kind, format, project: project).utf8).write(to: url, options: .atomic)
            model.lastError = nil
            model.statusMessage = "Saved \(kind.title.lowercased()) to \(url.lastPathComponent)"
        } catch {
            model.lastError = "Could not save \(kind.title.lowercased()): \(userMessage(for: error))"
        }
    }
}
