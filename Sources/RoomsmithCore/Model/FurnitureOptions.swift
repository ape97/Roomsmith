import Foundation

// MARK: - Furniture options (variants)

/// What one option choice does to one component. nil fields leave the component alone. Options never change size or
/// pose, only the material and whether the part is drawn.
public struct OptionEffect: Codable, Hashable, Sendable {
    public var materialId: UUID?
    /// false hides the component; true keeps it as visible as its state pose allows (it never shows a part the
    /// design or the state hides).
    public var visible: Bool?
    public init(materialId: UUID? = nil, visible: Bool? = nil) { self.materialId = materialId; self.visible = visible }
    public var isEmpty: Bool { materialId == nil && visible == nil }
}

/// One selectable value of an option group, e.g. the front colour "Oak".
public struct OptionChoice: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// Component id → effect while this choice is selected.
    public var effects: [UUID: OptionEffect] = [:]
    public init(id: UUID = UUID(), name: String, effects: [UUID: OptionEffect] = [:]) {
        self.id = id; self.name = name; self.effects = effects
    }
}

/// A switchable aspect of a design (colour, front, handle). Each placed piece selects one choice per group.
public struct OptionGroup: Codable, Hashable, Identifiable, Sendable {
    public static let maxPerDefinition = 12
    public static let maxChoices = 24

    public var id: UUID
    public var name: String
    public var choices: [OptionChoice]
    /// Choice used while a piece has not selected one; nil = the first choice.
    public var defaultChoiceId: UUID?
    public init(id: UUID = UUID(), name: String, choices: [OptionChoice], defaultChoiceId: UUID? = nil) {
        self.id = id; self.name = name; self.choices = choices; self.defaultChoiceId = defaultChoiceId
    }

    /// The choice in force for a selection: the selected one when this group still has it, else the default, else the first.
    public func effectiveChoice(selected: UUID?) -> OptionChoice? {
        if let selected, let c = choices.first(where: { $0.id == selected }) { return c }
        if let d = defaultChoiceId, let c = choices.first(where: { $0.id == d }) { return c }
        return choices.first
    }

    /// Components whose material any choice of this group sets.
    public var materialComponentIds: Set<UUID> {
        var out = Set<UUID>()
        for c in choices { for (cid, e) in c.effects where e.materialId != nil { out.insert(cid) } }
        return out
    }
}

/// The combined effect of an instance's option selection.
public struct OptionOutcome: Sendable, Equatable {
    /// Component id → material set by an option.
    public var materials: [UUID: UUID] = [:]
    /// Components an option hides.
    public var hidden: Set<UUID> = []
    public static let none = OptionOutcome()
    public init() {}
}

public extension FurnitureResolver {
    /// Resolves the option selection of an instance. Groups apply in definition order; when two groups touch the same
    /// component and property, the later group wins. Stale selections (group or choice no longer there) fall back to
    /// the group's default.
    static func optionOutcome(of inst: FurnitureInstance, definition def: FurnitureDefinition) -> OptionOutcome {
        guard !def.optionGroups.isEmpty else { return .none }
        var out = OptionOutcome()
        for g in def.optionGroups {
            guard let choice = g.effectiveChoice(selected: inst.optionSelection[g.id]) else { continue }
            for (cid, e) in choice.effects {
                if let m = e.materialId { out.materials[cid] = m }
                if let v = e.visible { if v { out.hidden.remove(cid) } else { out.hidden.insert(cid) } }
            }
        }
        return out
    }

    /// The material an instance draws a component with: its own override, else the option, else the design's.
    static func materialId(of c: Component, inst: FurnitureInstance, options: OptionOutcome) -> UUID? {
        inst.materialOverrides[c.id] ?? options.materials[c.id] ?? c.materialId
    }
}
