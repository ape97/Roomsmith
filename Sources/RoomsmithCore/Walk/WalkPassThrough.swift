import Foundation

/// Walk mode: holding Space switches the collision off for as long as it is held. It is not a setting and never touches
/// the document; the decision is a pure function of the stored setting and the key state.
public enum WalkPassThrough {
    /// Whether walls and furniture block the walker right now.
    public static func collides(setting: Bool, spaceHeld: Bool) -> Bool { setting && !spaceHeld }

    /// The collider that applies right now: `collider` while collision is on and Space is up, else nil (walks through).
    public static func activeCollider(_ collider: WalkCollider?, setting: Bool, spaceHeld: Bool) -> WalkCollider? {
        collides(setting: setting, spaceHeld: spaceHeld) ? collider : nil
    }

    /// Where the walker stands once Space is released: the nearest free spot when it stopped inside a wall or a piece of
    /// furniture (`WalkCollider.resolve` pushes it out by the shortest way), else where it is.
    public static func settled(_ position: V2, collider: WalkCollider?, setting: Bool) -> V2 {
        guard setting, let collider else { return position }
        return collider.resolve(position)
    }
}
