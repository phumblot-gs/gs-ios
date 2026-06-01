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
    /// Every other key found under `extra` — chiefly the account's
    /// custom catalog columns (`prefs.catalog_extra_cols`), whose
    /// values live here under their `key` (e.g. `supplier`,
    /// `ATS_COMPOSITION_PCP`). Captured generically so the reference
    /// info block can surface any configured column.
    public let columns: [String: ReferenceExtraValue]

    public init(
        measures: [String: MeasureValue]? = nil,
        techViews: TechViews? = nil,
        columns: [String: ReferenceExtraValue] = [:]
    ) {
        self.measures = measures
        self.techViews = techViews
        self.columns = columns
    }

    /// Display string for a custom catalog column, or nil when absent
    /// or not renderable (objects, empty values).
    public func displayValue(forKey key: String) -> String? {
        columns[key]?.displayString
    }

    private enum CodingKeys: String, CodingKey {
        case measures
        case techViews = "tech_views"
    }

    private struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: any Decoder) throws {
        let fixed = try decoder.container(keyedBy: CodingKeys.self)
        measures = try fixed.decodeIfPresent([String: MeasureValue].self, forKey: .measures)
        techViews = try fixed.decodeIfPresent(TechViews.self, forKey: .techViews)

        var captured: [String: ReferenceExtraValue] = [:]
        if let dynamic = try? decoder.container(keyedBy: DynamicKey.self) {
            for key in dynamic.allKeys where key.stringValue != "measures" && key.stringValue != "tech_views" {
                if let value = try? dynamic.decode(ReferenceExtraValue.self, forKey: key) {
                    captured[key.stringValue] = value
                }
            }
        }
        columns = captured
    }

    public func encode(to encoder: any Encoder) throws {
        var fixed = encoder.container(keyedBy: CodingKeys.self)
        try fixed.encodeIfPresent(measures, forKey: .measures)
        try fixed.encodeIfPresent(techViews, forKey: .techViews)
        var dynamic = encoder.container(keyedBy: DynamicKey.self)
        for (key, value) in columns {
            try dynamic.encode(value, forKey: DynamicKey(stringValue: key))
        }
    }
}

/// A loosely-typed JSON value captured from the `extra` blob. Only the
/// shapes we display are special-cased; everything else renders to nil.
public indirect enum ReferenceExtraValue: Sendable, Hashable, Codable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([ReferenceExtraValue])
    case object([String: ReferenceExtraValue])
    case null

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int.self) { self = .int(i); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([ReferenceExtraValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: ReferenceExtraValue].self) { self = .object(o); return }
        self = .null
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .bool(let b): try c.encode(b)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        case .null: try c.encodeNil()
        }
    }

    /// Human-readable rendering for the info table. Arrays are joined
    /// by ", "; objects and null render to nil (nothing to show). A
    /// true boolean shows a check; a false one is treated as "unset".
    public var displayString: String? {
        switch self {
        case .string(let s):
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .int(let i): return String(i)
        case .double(let d): return d == d.rounded() ? String(Int(d)) : String(d)
        case .bool(let b): return b ? "✓" : nil
        case .array(let a):
            let parts = a.compactMap(\.displayString)
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        case .object, .null: return nil
        }
    }
}
