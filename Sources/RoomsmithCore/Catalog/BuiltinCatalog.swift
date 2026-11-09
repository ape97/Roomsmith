import Foundation

/// One entry of the built-in catalog. `make` builds a fresh, complete definition with stable ids.
public struct CatalogEntry: Sendable {
    public var key: String
    public var name: String
    public var category: String
    public var tags: [String]
    public var make: @Sendable () -> FurnitureDefinition

    /// `make` is wrapped so that it always returns the complete catalog definition (name, category, tags, builtin, catalogKey).
    public init(key: String, name: String, category: String, tags: [String], make: @escaping @Sendable () -> FurnitureDefinition) {
        self.key = key; self.name = name; self.category = category; self.tags = tags
        self.make = {
            var def = make()
            def.name = name
            def.category = category
            def.tags = tags
            def.builtin = true
            def.catalogKey = key
            return def
        }
    }
}

/// Original furniture designs built from primitives. Coordinates: origin at the footprint centre on the floor,
/// front = −Y, back = +Y, Z up. Wall-mounted pieces start at z = 0 in their definition; place the instance at the mounting height.
public enum BuiltinCatalog {
    public static let categories = ["Living", "Bedroom", "Kitchen", "Bathroom", "Office", "Dining", "Decor", "Lighting"]

    public static let entries: [CatalogEntry] = makeEntries()

    /// The few built-in pieces the sidebar shows as "Examples" (the full catalog stays available to agent tools and benchmarks).
    public static let exampleKeys = ["sofa.3seat.2100", "table.dining.1600", "chair.dining", "bed.double.1600", "wardrobe.2000"]

    /// The example pieces that match a search text (all of them for empty text), in `exampleKeys` order.
    public static func examples(matching text: String) -> [CatalogEntry] {
        let hits = Set(search(text).map(\.key))
        return exampleKeys.compactMap { key in entries.first { $0.key == key } }.filter { hits.contains($0.key) }
    }

    public static let materials: [Material] = Palette.all

    /// Builds the definition of a catalog entry (builtin = true, catalogKey = key, deterministic ids).
    public static func definition(_ key: String) -> FurnitureDefinition? {
        guard let entry = entries.first(where: { $0.key == key }) else { return nil }
        return entry.make()
    }

    /// Case-insensitive search: every word must occur in the name, key, category or one of the tags. Empty text returns all.
    public static func search(_ text: String) -> [CatalogEntry] {
        let words = text.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return entries }
        return entries.filter { entry in
            let haystack = ([entry.name, entry.key, entry.category] + entry.tags).joined(separator: " ").lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }
}
