import Foundation

/// Turns any error into one readable sentence (or two) for the status bar and dialogs: what happened, and where it
/// helps, what to do next. Never prints Swift type names or enum dumps.
public func userMessage(for error: Error) -> String {
    switch error {
    case let e as CommandError:
        return e.message
    case let e as AgentError:
        return e.message
    case let e as LibraryError:
        return e.description
    case let e as PhotoAnalysisError:
        return e.message
    case let e as PlanRaster.Failure:
        return e.description
    case let e as WalkMeasureError:
        switch e { case .notFound(let m), .invalid(let m): return m }
    case let e as PersistenceError:
        return "\(e.description). Check that the file is a valid Roomsmith project, then try again."
    case let e as CocoaError:
        switch e.code {
        case .fileNoSuchFile, .fileReadNoSuchFile:
            return "The file does not exist. Check that it was not moved or deleted."
        case .fileReadNoPermission, .fileWriteNoPermission:
            return "Roomsmith has no permission for this file. Check the file and folder permissions."
        case .fileWriteOutOfSpace:
            return "The disk is full. Free some space and try again."
        case .fileWriteVolumeReadOnly:
            return "The disk is read-only. Choose another location."
        case .fileReadCorruptFile, .fileReadUnknown, .propertyListReadCorrupt:
            return "The file could not be read. Check that it is not damaged and try again."
        default:
            return "\(cleaned(e.localizedDescription)) Check the file and try again."
        }
    case let e as LocalizedError:
        if let text = e.errorDescription, !text.isEmpty { return text }
        return generic
    default:
        let ns = error as NSError
        // Foundation-bridged errors have a readable text; plain Swift enums only give "The operation couldn't be completed. (… error 1.)".
        if ns.domain == NSCocoaErrorDomain || ns.domain == NSPOSIXErrorDomain || ns.domain == NSURLErrorDomain {
            return "\(cleaned(ns.localizedDescription)) Check the file and try again."
        }
        return generic
    }
}

private let generic = "Something went wrong. Try again; if it keeps happening, save your work and restart Roomsmith."

private func cleaned(_ s: String) -> String {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return t.hasSuffix(".") ? t : t + "."
}

/// Spoken summary of the drawing for VoiceOver (plan and 3D view).
public enum SceneSummary {
    public static func text(_ p: Project, levelId: UUID, selected: Int, view: String) -> String {
        let levelName = p.level(levelId)?.name ?? "level"
        let rooms = p.rooms.filter { $0.levelId == levelId }.count
        let walls = p.walls.filter { $0.levelId == levelId }.count
        let furniture = p.instances.filter { $0.levelId == levelId }.count
        func n(_ c: Int, _ one: String, _ many: String) -> String { "\(c) \(c == 1 ? one : many)" }
        var s = "\(view) of \(levelName): \(n(rooms, "room", "rooms")), \(n(walls, "wall", "walls")), \(n(furniture, "furniture item", "furniture items"))"
        s += selected > 0 ? ", \(selected) selected" : ", nothing selected"
        return s
    }
}
