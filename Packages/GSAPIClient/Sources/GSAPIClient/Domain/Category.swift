import Foundation

/// A shooting category that defines the expected views (`view_types`) for
/// every reference linked to it. Fetched from `/specification/category` at
/// app startup and cached locally for the duration of the session.
public struct Category: Sendable, Hashable, Identifiable, Codable {
    public let id: Int
    public let smalltext: String?
    public let ranking: Int?
    public let keywords: [String]?
    public let viewTypes: [ViewType]

    public init(
        id: Int,
        smalltext: String? = nil,
        ranking: Int? = nil,
        keywords: [String]? = nil,
        viewTypes: [ViewType] = []
    ) {
        self.id = id
        self.smalltext = smalltext
        self.ranking = ranking
        self.keywords = keywords
        self.viewTypes = viewTypes
    }

    private enum CodingKeys: String, CodingKey {
        case id = "category_id"
        case smalltext
        case ranking
        case keywords
        case viewTypes = "view_types"
    }

    /// View types ordered by `rang` ascending, ready to drive a "shot list".
    public var viewTypesByRang: [ViewType] {
        viewTypes.sorted { $0.rang < $1.rang }
    }
}
