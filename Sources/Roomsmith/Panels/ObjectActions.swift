import AppKit
import Foundation
import RoomsmithCore

/// Selection actions shared by the sidebar context menu, the inspector and the Arrange menu.
/// Every change is one command in the document store.
extension AppModel {
    // MARK: Classification

    var selectionIds: [UUID] { Array(selection) }

    func isFurniture(_ id: UUID) -> Bool { project.instance(id) != nil }
    func isGroup(_ id: UUID) -> Bool { project.group(id) != nil }

    /// Furniture that is selected, not yet in a group and can be grouped.
    func groupableIds(_ ids: [UUID]) -> [UUID] {
        ids.filter { project.instance($0).map { $0.groupId == nil } ?? false }
    }

    /// Groups that the ids refer to (the group itself, or the group of a selected member).
    func groupIds(for ids: [UUID]) -> [UUID] {
        var out: [UUID] = []
        for id in ids {
            let gid = project.group(id) != nil ? id : project.instance(id)?.groupId
            if let gid, !out.contains(gid) { out.append(gid) }
        }
        return out
    }

    func lockableIds(_ ids: [UUID]) -> [UUID] {
        ids.filter { id in
            guard let k = project.kind(of: id) else { return false }
            return k == .wall || k == .furniture || k == .group
        }
    }

    func hideableIds(_ ids: [UUID]) -> [UUID] {
        ids.filter { id in
            guard let k = project.kind(of: id) else { return false }
            return k == .furniture || k == .group
        }
    }

    func isLockedForMenu(_ id: UUID) -> Bool {
        if let w = project.wall(id) { return w.locked }
        if let i = project.instance(id) { return i.locked }
        if let g = project.group(id) { return g.locked }
        return false
    }

    func isHidden(_ id: UUID) -> Bool {
        if let i = project.instance(id) { return !i.visible }
        if let g = project.group(id) { return g.memberIds.allSatisfy { project.instance($0)?.visible == false } && !g.memberIds.isEmpty }
        return false
    }

    var textEditingActive: Bool { NSApp.keyWindow?.firstResponder is NSText }

    // MARK: Actions

    func deleteObjects(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        perform(ids.count == 1 ? "Delete \(project.displayName(of: ids[0]))" : "Delete \(ids.count) Objects") { p in
            // Members of a deleted group are deleted with it; skip ids that vanish on the way.
            for id in ids where p.kind(of: id) != nil { try p.deleteObjects([id]) }
        }
    }

    /// Bare Delete/Backspace: removes the unlocked part of `ids` (locked objects stay, as with every other edit).
    /// True when something was deleted.
    @discardableResult
    func deleteUnlocked(_ ids: [UUID]) -> Bool {
        let free = ids.filter { !isLockedForMenu($0) }
        guard !free.isEmpty else { return false }
        deleteObjects(free)
        return true
    }

    func duplicateObjects(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        var map: [UUID: UUID] = [:]
        let ok = perform("Duplicate") { p in map = try p.duplicateObjects(ids) }
        if ok {
            let created = ids.compactMap { map[$0] }
            if !created.isEmpty { selection = Set(created) }
        }
    }

    func groupObjects(_ ids: [UUID]) {
        let members = groupableIds(ids)
        guard !members.isEmpty else { return }
        var gid: UUID?
        let name = "Group \(project.groups.count + 1)"
        if perform("Group") { p in gid = try p.groupObjects(members, name: name) }, let gid { selection = [gid] }
    }

    func ungroupObjects(_ ids: [UUID]) {
        let gids = groupIds(for: ids)
        guard !gids.isEmpty else { return }
        var freed: [UUID] = []
        if perform("Ungroup") { p in for g in gids { freed += try p.ungroup(g) } } { selection = Set(freed) }
    }

    func toggleLock(_ ids: [UUID]) {
        let targets = lockableIds(ids)
        guard !targets.isEmpty else { return }
        let lock = !targets.allSatisfy { isLockedForMenu($0) }
        perform(lock ? "Lock" : "Unlock") { p in try p.setLocked(targets, lock) }
    }

    func toggleVisible(_ ids: [UUID]) {
        let targets = hideableIds(ids)
        guard !targets.isEmpty else { return }
        let show = targets.allSatisfy { isHidden($0) }
        perform(show ? "Show" : "Hide") { p in try p.setVisible(targets, show) }
    }

    func rotate(_ ids: [UUID], by deg: Double) {
        guard !ids.isEmpty else { return }
        perform("Rotate") { p in try p.rotateObjects(ids, by: deg) }
    }

    func frame(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        selection = Set(ids)
        frameSelectionRequest += 1
    }

    func selectAllOnLevel() {
        let p = project, lid = activeLevelId
        var ids: [UUID] = []
        ids += p.walls.filter { $0.levelId == lid }.map(\.id)
        ids += p.rooms.filter { $0.levelId == lid }.map(\.id)
        ids += p.dimensions.filter { $0.levelId == lid }.map(\.id)
        ids += p.groups.filter { $0.levelId == lid }.map(\.id)
        ids += p.instances.filter { $0.levelId == lid && $0.groupId == nil && $0.visible }.map(\.id)
        selection = Set(ids)
    }

    // MARK: Catalog placement

    /// Centre of the selected room(s) on the active level, else of everything on the level, else the origin.
    func placementPoint() -> P2 {
        let p = project
        let rooms = selection.filter { p.room($0) != nil }
        if !rooms.isEmpty, let c = p.boundsCenter(Array(rooms)) { return c }
        let lid = activeLevelId
        var ids = p.walls.filter { $0.levelId == lid }.map(\.id)
        ids += p.rooms.filter { $0.levelId == lid }.map(\.id)
        ids += p.instances.filter { $0.levelId == lid }.map(\.id)
        return p.boundsCenter(ids) ?? P2(0, 0)
    }

    /// Places a built-in catalog entry on the active level and selects it.
    func addCatalogEntry(key: String) {
        guard let level = activeLevel else { return }
        let at = placementPoint()
        var newId: UUID?
        let title = BuiltinCatalog.entries.first { $0.key == key }?.name ?? "Furniture"
        let ok = perform("Add \(title)") { p in
            guard let def = BuiltinCatalog.definition(key) else { throw CommandError.invalid("Unknown catalog entry \(key)") }
            // Reuse the definition if this key was added before (also keeps user edits of the project copy).
            let defId = p.definitions.first { $0.catalogKey == key }?.id ?? p.addDefinition(def)
            for mid in Set(def.components.compactMap(\.materialId)) where p.material(mid) == nil {
                if let m = BuiltinCatalog.materials.first(where: { $0.id == mid }) { p.addMaterial(m) }
            }
            newId = try p.addInstance(definitionId: defId, levelId: level.id, position: P3(at.x, at.y, 0))
        }
        if ok, let newId { selection = [newId] }
    }

    func addModularSofa() {
        guard let level = activeLevel else { return }
        let at = placementPoint()
        var gid: UUID?
        if perform("Add Modular Sofa", { p in gid = try BuiltinCatalog.insertModularSofa(into: &p, levelId: level.id, origin: at) }), let gid {
            selection = [gid]
        }
    }

    /// Places an existing project definition (builder or import).
    func addDefinitionInstance(_ definitionId: UUID) {
        guard let level = activeLevel, let def = project.definition(definitionId) else { return }
        let at = placementPoint()
        var newId: UUID?
        if perform("Add \(def.name)", { p in newId = try p.addInstance(definitionId: definitionId, levelId: level.id, position: P3(at.x, at.y, 0)) }),
           let newId {
            selection = [newId]
        }
    }
}
