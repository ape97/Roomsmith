import Foundation

// Lighting edits. Light is document state, so the app and the agent change it only through these (undoable via DocumentStore.run).
public extension Project {
    mutating func updateLighting(_ body: (inout LightingSettings) throws -> Void) rethrows { try body(&settings.lighting) }

    /// Applies a mood; with `setTime` the time of day jumps to the mood's suggested time.
    mutating func applyMood(_ mood: LightMood, setTime: Bool) {
        if setTime { settings.lighting = settings.lighting.applying(mood: mood) } else { settings.lighting.mood = mood }
    }

    /// Adds a lamp to a design, or replaces the lamp with the same id.
    mutating func setEmitter(_ e: LightEmitter, in definitionId: UUID) throws {
        try updateDefinition(definitionId) { d in
            if let i = d.lights.firstIndex(where: { $0.id == e.id }) { d.lights[i] = e } else { d.lights.append(e) }
        }
    }

    mutating func removeEmitter(_ emitterId: UUID, from definitionId: UUID) throws {
        guard let d = definition(definitionId) else { throw CommandError.notFound("Definition", definitionId) }
        guard d.lights.contains(where: { $0.id == emitterId }) else { throw CommandError.notFound("Lamp", emitterId) }
        try updateDefinition(definitionId) { $0.lights.removeAll { $0.id == emitterId } }
    }

    /// Switches the lamps of a placed piece. Allowed on locked pieces: it moves nothing.
    mutating func setLightOn(_ on: Bool, instance id: UUID) throws {
        if kind(of: id) == nil { throw CommandError.notFound("Furniture", id) }
        try modify(\.instances, id, "Furniture") { $0.lightOn = on }
    }
}
