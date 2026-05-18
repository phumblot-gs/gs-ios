import Foundation

/// Physical storage zone in the studio (room, aisle, etc.). Optional grouping
/// above batches. Many GS accounts have none — the UI hides every zone
/// control when `CatalogCache.zones` is empty.
public struct Zone: Sendable, Hashable, Identifiable, Codable {
    public let id: Int
    public let smalltext: String?

    public init(id: Int, smalltext: String?) {
        self.id = id
        self.smalltext = smalltext
    }

    private enum CodingKeys: String, CodingKey {
        case id = "zone_id"
        case smalltext
    }
}
