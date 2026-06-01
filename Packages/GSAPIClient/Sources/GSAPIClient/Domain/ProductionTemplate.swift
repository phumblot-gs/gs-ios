import Foundation

/// A production template declared on the Grand Shooting account —
/// fetched from `/production/template`. A template bundles a
/// production's config (exports, metadata, validation phases…); when
/// the user picks one in Settings its `id` is passed as `template_id`
/// at production-creation time so the new production inherits that
/// config. We only decode the two fields the app needs — `template_id`
/// for the payload and `smalltext` for display — and ignore the rest
/// of the (large) template body.
public struct ProductionTemplate: Sendable, Hashable, Identifiable, Codable {
    public let id: Int
    public let name: String

    public init(id: Int, name: String) {
        self.id = id
        self.name = name
    }

    private enum CodingKeys: String, CodingKey {
        case id = "template_id"
        case name = "smalltext"
    }
}
