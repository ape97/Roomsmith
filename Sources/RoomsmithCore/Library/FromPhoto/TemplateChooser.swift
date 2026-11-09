import Foundation

/// Rule table that maps classifier labels and hint words (German and English) to builder templates.
/// Matching is on lower-cased, diacritic-folded words. A word that ends in a keyword counts for that keyword (so a German
/// compound such as "Couchtisch" is a table, "Nachttisch" a cabinet because the longer keyword wins), otherwise the longest
/// keyword it contains counts.
public enum PhotoKeywords {
    struct Rule: Sendable {
        var text: String
        var template: BuilderTemplate
        var weight: Double
        /// Short words that must match the whole word (so "leg" does not fire inside "legal").
        var whole: Bool
    }

    private static func r(_ t: BuilderTemplate, _ w: Double, whole: Bool = false, _ words: String...) -> [Rule] {
        words.map { Rule(text: $0, template: t, weight: w, whole: whole) }
    }

    static let rules: [Rule] =
        r(.sofa, 1.0, "sofa", "couch", "settee", "loveseat", "sectional", "polster", "sitzbank", "recamiere")
        + r(.sofa, 0.8, "armchair", "sessel", "lounge")
        + r(.sofa, 0.6, "armrest", "armlehne", "armlehnen", "bench", "cushion", "kissen")
        + r(.sofa, 0.6, whole: true, "chair", "stuhl", "seat", "sitz")
        + r(.table, 1.0, "table", "tisch", "desk", "schreibtisch", "esstisch", "couchtisch", "worktop", "arbeitsplatte")
        + r(.table, 0.6, whole: true, "leg", "legs", "bein", "beine", "tabletop", "tischplatte")
        + r(.cabinet, 1.0, "cabinet", "schrank", "kommode", "dresser", "sideboard", "wardrobe", "cupboard", "commode", "nightstand",
                           "nachttisch", "kleiderschrank", "anrichte", "vitrine", "buffet", "tvboard", "lowboard", "highboard")
        + r(.cabinet, 0.8, "drawer", "drawers", "schublade", "schubladen", "chestofdrawers")
        + r(.cabinet, 0.4, whole: true, "door", "doors", "tur", "turen")
        + r(.shelf, 1.0, "regal", "bookcase", "bookshelf", "bucherregal", "etagere", "shelving", "wandregal", "bucherschrank")
        + r(.shelf, 0.5, "shelf", "shelves")
        + r(.shelf, 0.5, whole: true, "rack", "fach", "facher", "board")
        + r(.box, 1.0, "box", "kiste", "wurfel", "cube", "crate", "truhe", "container", "pouf", "pouffe", "ottoman")
        + r(.box, 0.5, "stool", "hocker", "planter", "pflanzkubel")
        + r(.box, 0.5, whole: true, "chest", "bed", "bett", "block")

    /// Splits text into folded lower-case words.
    static func words(_ text: String) -> [String] {
        let folded = text.lowercased().replacingOccurrences(of: "ß", with: "ss")
            .folding(options: [.diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return folded.split(whereSeparator: { !$0.isLetter }).map(String.init).filter { !$0.isEmpty }
    }

    /// The rule a word counts for, or nil.
    static func match(_ word: String) -> Rule? {
        var best: Rule?
        var bestScore = -1
        for rule in rules {
            if rule.whole {
                if word == rule.text { return rule }
                continue
            }
            guard word.contains(rule.text) else { continue }
            // Suffix hits rank above inner hits; within a class the longer keyword wins.
            let score = (word.hasSuffix(rule.text) ? 1000 : 0) + rule.text.count
            if score > bestScore || (score == bestScore && rule.weight > (best?.weight ?? 0)) { best = rule; bestScore = score }
        }
        return best
    }
}

public struct TemplateScore: Sendable, Equatable {
    public var template: BuilderTemplate
    public var score: Double
}

/// The outcome of choosing a template.
public struct TemplateChoice: Sendable, Equatable {
    /// All templates, best first (ties by template order).
    public var ranking: [TemplateScore]
    /// True when nothing in the evidence pointed to a template and `box` was used as fallback.
    public var fallback: Bool
    /// True when the runner-up is nearly as good as the winner; the caller should say so.
    public var ambiguous: Bool
    /// Words that decided (for the user: "why this template").
    public var reasons: [String]

    public var template: BuilderTemplate { ranking.first?.template ?? .box }
    public var score: Double { ranking.first?.score ?? 0 }
    public func score(of t: BuilderTemplate) -> Double { ranking.first { $0.template == t }?.score ?? 0 }
}

public enum TemplateChooser {
    /// A hint word counts more than a classifier label (the user knows what the piece is).
    static let hintFactor = 1.5
    /// A runner-up with at least this share of the winner's score makes the choice ambiguous.
    static let ambiguousShare = 0.6
    /// How far a new template must lead the current one before an existing design switches (see `ParamMerge`).
    public static let switchMargin = 0.5

    public static func choose(analysis: PhotoAnalysis, hint: String = "") -> TemplateChoice {
        var scores: [BuilderTemplate: Double] = [:]
        var reasons: [String] = []
        func add(_ words: [String], factor: Double, source: String) {
            for w in words {
                guard let rule = PhotoKeywords.match(w) else { continue }
                scores[rule.template, default: 0] += rule.weight * factor
                reasons.append("\(source) \"\(w)\" suggests \(rule.template.rawValue)")
            }
        }
        for l in analysis.labels where l.confidence > 0 {
            add(PhotoKeywords.words(l.name), factor: min(1, l.confidence), source: "label")
        }
        add(PhotoKeywords.words(hint), factor: hintFactor, source: "hint")
        add(analysis.hintKeywords.sorted().flatMap(PhotoKeywords.words), factor: 1, source: "keyword")

        let order = BuilderTemplate.allCases
        var ranking = order.map { TemplateScore(template: $0, score: scores[$0] ?? 0) }
        ranking.sort { a, b in
            a.score != b.score ? a.score > b.score : order.firstIndex(of: a.template)! < order.firstIndex(of: b.template)!
        }
        let top = ranking[0].score
        if top <= 0 {
            // Unknown evidence: a plain box is the safest guess.
            ranking = ([BuilderTemplate.box] + order.filter { $0 != .box }).map { TemplateScore(template: $0, score: 0) }
            return TemplateChoice(ranking: ranking, fallback: true, ambiguous: false, reasons: ["nothing recognised; using a plain box"])
        }
        let second = ranking[1].score
        return TemplateChoice(ranking: ranking, fallback: false, ambiguous: second > 0 && second >= ambiguousShare * top, reasons: reasons)
    }
}
