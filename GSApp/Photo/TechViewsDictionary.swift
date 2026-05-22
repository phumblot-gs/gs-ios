import Foundation

/// Small built-in lookup that maps common label terms across the
/// languages we typically see on textile / cosmetics labels (FR, IT,
/// ES, DE, PL, PT…) onto a single English canonical form. Used by
/// the OCR pipeline to deduplicate multilingual repetitions on the
/// same line ("wool lana" → "wool") and across lines ("Made in
/// Portugal" / "Fabriqué au Portugal" → "Made in Portugal").
///
/// The list is intentionally narrow: textile materials + a few
/// catch-all care words. Expanding it later is a one-line addition
/// per concept.
enum TechViewsDictionary {

    /// English canonical → known synonyms across languages
    /// (case-insensitive on lookup).
    static let synonyms: [String: Set<String>] = [
        "wool":       ["wool", "laine", "lana", "wolle", "schurwolle", "lã"],
        "cotton":     ["cotton", "coton", "cotone", "baumwolle", "algodón", "algodao", "bawełna"],
        "silk":       ["silk", "soie", "seta", "seda", "seide", "jedwab"],
        "linen":      ["linen", "lin", "lino", "leinen", "len"],
        "polyester":  ["polyester", "polyestere", "poliester", "poliéster", "poliestere"],
        "nylon":      ["nylon", "nilon"],
        "acrylic":    ["acrylic", "acrylique", "acrilico", "acrílico", "akryl", "acryl", "acrylkio", "acrykio"],
        "viscose":    ["viscose", "viscosa", "viskose", "wiskoza"],
        "mohair":     ["mohair", "moher"],
        "polyamide":  ["polyamide", "poliamida", "poliammide", "poliamid"],
        "elastane":   ["elastane", "élasthanne", "elastano", "spandex", "elastan"],
        "leather":    ["leather", "cuir", "cuoio", "leder", "cuero", "skóra"],
        "rayon":      ["rayon", "rayonne"],
        "lycra":      ["lycra"],
        "modal":      ["modal"],
        "cashmere":   ["cashmere", "cachemire", "cachemira", "kaschmir"],
        "alpaca":     ["alpaca", "alpaga", "alpaka"]
    ]

    /// Reverse index built once at app launch.
    private static let canonicalIndex: [String: String] = {
        var out: [String: String] = [:]
        for (canonical, set) in synonyms {
            for synonym in set {
                out[synonym.lowercased()] = canonical
            }
        }
        return out
    }()

    /// English canonical for a token, or nil when nothing matches.
    static func canonical(of token: String) -> String? {
        canonicalIndex[token.lowercased()]
    }
}
