import Foundation

/// Freeform `extra` blob attached to a `Reference`. We model the
/// fields the app actually reads (measures, tech_views) and let any
/// other keys returned by GS round-trip through. Decoded as part of
/// the `Reference` payload; writes go through `ReferenceExtraService`.
public struct ReferenceExtra: Sendable, Hashable, Codable {

    public struct MeasureValue: Sendable, Hashable, Codable {
        public let value: Double
        public let unit: String

        public init(value: Double, unit: String) {
            self.value = value
            self.unit = unit
        }
    }

    /// Structured technical-view information extracted from product
    /// labels via OCR + pictogram recognition. Every field is
    /// optional — categories the user hasn't filled in are simply
    /// absent from the GS payload (PUT merges with whatever's there).
    public struct TechViews: Sendable, Hashable, Codable {
        public let provenance: String?
        public let composition: String?
        public let care: String?
        public let standards: String?
        public let restrictions: String?
        public let notes: String?

        public init(
            provenance: String? = nil,
            composition: String? = nil,
            care: String? = nil,
            standards: String? = nil,
            restrictions: String? = nil,
            notes: String? = nil
        ) {
            self.provenance = provenance
            self.composition = composition
            self.care = care
            self.standards = standards
            self.restrictions = restrictions
            self.notes = notes
        }
    }

    /// Named measurements, keyed by their semantic name (`"sleeve"`,
    /// `"chest"`, …). Nil when GS hasn't received any yet.
    public let measures: [String: MeasureValue]?
    public let techViews: TechViews?

    public init(measures: [String: MeasureValue]? = nil, techViews: TechViews? = nil) {
        self.measures = measures
        self.techViews = techViews
    }

    private enum CodingKeys: String, CodingKey {
        case measures
        case techViews = "tech_views"
    }
}
