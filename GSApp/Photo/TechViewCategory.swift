import Foundation

/// Categories the user picks for OCR-extracted text (and, later,
/// pictograms). The rawValue doubles as the JSON key on GS under
/// `extra.tech_views`, so renaming a case is a breaking change.
enum TechViewCategory: String, CaseIterable, Identifiable, Hashable, Sendable {
    case provenance
    case composition
    case care
    case standards
    case restrictions
    case notes

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .provenance:   return String(localized: "Origin")
        case .composition:  return String(localized: "Composition")
        case .care:         return String(localized: "Care")
        case .standards:    return String(localized: "Standards")
        case .restrictions: return String(localized: "Restrictions")
        case .notes:        return String(localized: "Notes")
        }
    }

    var symbolName: String {
        switch self {
        case .provenance:   return "globe.europe.africa"
        case .composition:  return "leaf"
        case .care:         return "drop"
        case .standards:    return "rosette"
        case .restrictions: return "exclamationmark.shield"
        case .notes:        return "text.bubble"
        }
    }
}
