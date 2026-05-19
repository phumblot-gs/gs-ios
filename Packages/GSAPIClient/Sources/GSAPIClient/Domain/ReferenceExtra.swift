import Foundation

/// Freeform `extra` blob attached to a `Reference`. We only model the
/// fields the app actually reads — `measures` today — and let any other
/// keys returned by GS round-trip through. Decoded as part of the
/// `Reference` payload; writes go through `ReferenceExtraService`.
public struct ReferenceExtra: Sendable, Hashable, Codable {

    public struct MeasureValue: Sendable, Hashable, Codable {
        public let value: Double
        public let unit: String

        public init(value: Double, unit: String) {
            self.value = value
            self.unit = unit
        }
    }

    /// Named measurements, keyed by their semantic name (`"sleeve"`,
    /// `"chest"`, …). Nil when GS hasn't received any yet.
    public let measures: [String: MeasureValue]?

    public init(measures: [String: MeasureValue]? = nil) {
        self.measures = measures
    }
}
