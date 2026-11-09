import Foundation

/// Rules of the view-only Hand tool, shared by the plan and the 3D view. The Hand tool (or Space held down) only
/// navigates: clicks select nothing, drags move nothing, editing keys do nothing. The views ask these functions so the
/// decisions are the same everywhere and testable without a window.
public enum HandMode {
    /// The view is in look-only mode: the Hand tool is active, or Space is held down as a temporary Hand.
    public static func isActive(toolIsHand: Bool, spaceHeld: Bool) -> Bool { toolIsHand || spaceHeld }

    /// Whether a click, drag or editing key may select, move, rotate, resize or delete scene content.
    /// `cameraAllowsEditing` is false in views that never edit (3D first person).
    public static func allowsEditing(toolIsHand: Bool, spaceHeld: Bool, cameraAllowsEditing: Bool = true) -> Bool {
        cameraAllowsEditing && !isActive(toolIsHand: toolIsHand, spaceHeld: spaceHeld)
    }

    /// Whether a left-button drag navigates (plan: pan; 3D: the camera drag of the current view mode) instead of editing.
    public static func leftDragNavigates(toolIsHand: Bool, spaceHeld: Bool) -> Bool {
        isActive(toolIsHand: toolIsHand, spaceHeld: spaceHeld)
    }

    /// Tool changes by a plain letter key.
    public enum Shortcut: Equatable, Sendable {
        case select, hand
    }

    /// V selects, H hands (any case). Not with Command, Control or Option; nothing for other keys or several characters.
    public static func shortcut(characters: String?, command: Bool, control: Bool, option: Bool) -> Shortcut? {
        guard !command, !control, !option, let characters, characters.count == 1 else { return nil }
        switch characters.lowercased() {
        case "v": return .select
        case "h": return .hand
        default: return nil
        }
    }

    /// Esc leaves the Hand tool for Select, unless Space is the only reason for look-only mode (releasing Space ends it).
    public static func escapeLeavesHand(toolIsHand: Bool) -> Bool { toolIsHand }
}
