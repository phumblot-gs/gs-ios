import Foundation

/// A shooting method declared on the Grand Shooting account — e.g.
/// "Packshot", "Editorial", "TechView". Fetched from `/shootingmethod`
/// and used to scope a production: each production is created under a
/// specific shooting method, and the technical-views uploads target a
/// production tied to the method the user selected in Settings.
public struct ShootingMethod: Sendable, Hashable, Identifiable, Codable {
    public let id: Int
    public let name: String

    public init(id: Int, name: String) {
        self.id = id
        self.name = name
    }

    private enum CodingKeys: String, CodingKey {
        case id = "shooting_method_id"
        case name = "shootingmethod"
    }
}
