import Foundation

public extension Project {
    /// Deletes a material, a furniture definition (design) or a product, but only when nothing uses it. This is the
    /// same rule as the agent tool `scene.delete_objects` (it refuses while `references(to:)` is not empty); the UI
    /// uses this command so that one call is one undo step and a used entry is never silently unlinked from the objects
    /// that use it. One link is not a use: deleting a design clears `definitionId` of a product made from it (the
    /// product stays; undo restores the link).
    /// - Throws: `CommandError.invalid` naming the entry and the number of objects that still use it; nothing changes then.
    mutating func deleteUnusedCatalogEntry(_ id: UUID) throws {
        guard let kind = kind(of: id) else { throw CommandError(.notFound, "Object \(id.uuidString.lowercased()) does not exist", ids: [id]) }
        let label: String
        switch kind {
        case .material: label = "material"
        case .definition: label = "design"
        case .product: label = "product"
        default: throw CommandError.invalid("Only materials, designs and products can be deleted here", ids: [id])
        }
        if kind == .definition, definition(id)?.builtin == true {
            throw CommandError.invalid("Built-in designs cannot be deleted", ids: [id])
        }
        let users = Set(references(to: id).map(\.id))
        if !users.isEmpty {
            throw CommandError.invalid("Cannot delete \(label) '\(displayName(of: id))': it is still used by \(users.count) object(s). Remove or replace those first",
                                       ids: [id] + users.sorted { $0.uuidString < $1.uuidString })
        }
        try deleteObjects([id])
    }
}
