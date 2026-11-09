import Foundation

/// The editable fields of `BuilderParams` (the material counts as one field).
public enum ParamField: String, CaseIterable, Codable, Sendable {
    case width, depth, height, shelves, doors, plinth, legInset, topThickness, boards, armWidth, seatHeight, material
}

public struct ParamMergeResult: Sendable, Equatable {
    public var spec: ParametricSpec
    /// Fields whose value differs from the old spec afterwards.
    public var changed: [ParamField]
    /// Fields that kept the old value because the user had edited them.
    public var kept: [ParamField]
    public var templateChanged: Bool
    /// Set when the new evidence points to another template but not clearly enough to switch.
    public var suggestedTemplate: BuilderTemplate?
}

/// Improving an existing design with a new photo: values the user edited stay, the rest follow the new proposal, and the
/// template changes only when the new evidence leads clearly (`TemplateChooser.switchMargin`).
public enum ParamMerge {
    public static func merge(current: ParametricSpec, proposed: ParametricSpec, currentTemplateScore: Double, proposedTemplateScore: Double,
                             keep: Set<ParamField>) -> ParamMergeResult {
        var template = current.template
        var suggested: BuilderTemplate?
        if proposed.template != current.template {
            if proposedTemplateScore - currentTemplateScore >= TemplateChooser.switchMargin { template = proposed.template }
            else { suggested = proposed.template }
        }
        var p = proposed.params
        if template != proposed.template {
            // The proposal was built for another template: only the sizes and the material carry over, the template-specific
            // parameters (doors, shelves, arm width, ...) stay as the entry has them.
            p = current.params
            for f in [ParamField.width, .depth, .height, .material] { set(f, from: proposed.params, into: &p) }
        }
        var kept: [ParamField] = []
        for f in ParamField.allCases where keep.contains(f) {
            if value(f, of: current.params) != value(f, of: proposed.params) { kept.append(f) }
            set(f, from: current.params, into: &p)
        }
        p = PhotoDimensioning.clamp(p)
        let spec = ParametricSpec(template: template, params: p)
        let changed = ParamField.allCases.filter { value($0, of: current.params) != value($0, of: p) }
        return ParamMergeResult(spec: spec, changed: changed, kept: kept, templateChanged: template != current.template,
                                suggestedTemplate: suggested)
    }

    static func value(_ f: ParamField, of p: BuilderParams) -> String {
        switch f {
        case .width: "\(p.width)"
        case .depth: "\(p.depth)"
        case .height: "\(p.height)"
        case .shelves: "\(p.shelves)"
        case .doors: "\(p.doors)"
        case .plinth: "\(p.plinth)"
        case .legInset: "\(p.legInset)"
        case .topThickness: "\(p.topThickness)"
        case .boards: "\(p.boards)"
        case .armWidth: "\(p.armWidth)"
        case .seatHeight: "\(p.seatHeight)"
        case .material: p.materialId?.uuidString ?? "-"
        }
    }

    static func set(_ f: ParamField, from s: BuilderParams, into p: inout BuilderParams) {
        switch f {
        case .width: p.width = s.width
        case .depth: p.depth = s.depth
        case .height: p.height = s.height
        case .shelves: p.shelves = s.shelves
        case .doors: p.doors = s.doors
        case .plinth: p.plinth = s.plinth
        case .legInset: p.legInset = s.legInset
        case .topThickness: p.topThickness = s.topThickness
        case .boards: p.boards = s.boards
        case .armWidth: p.armWidth = s.armWidth
        case .seatHeight: p.seatHeight = s.seatHeight
        case .material: p.materialId = s.materialId
        }
    }

    /// The fields the user pinned down by giving a dimension.
    public static func fields(of d: PhotoDimensions) -> Set<ParamField> {
        var s = Set<ParamField>()
        if d.width != nil { s.insert(.width) }
        if d.depth != nil { s.insert(.depth) }
        if d.height != nil { s.insert(.height) }
        return s
    }
}
