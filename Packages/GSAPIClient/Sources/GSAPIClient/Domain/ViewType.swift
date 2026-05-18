import Foundation

/// One expected shot of a category, identified by `code`. A category's
/// view_types are ordered by `rang` and define the "shot list" against
/// which actual pictures are matched.
public struct ViewType: Sendable, Hashable, Codable {
    public let code: String
    public let rang: Int
    public let smalltext: String?
    public let shootingmethod: String?
    public let description: String?

    public init(
        code: String,
        rang: Int,
        smalltext: String? = nil,
        shootingmethod: String? = nil,
        description: String? = nil
    ) {
        self.code = code
        self.rang = rang
        self.smalltext = smalltext
        self.shootingmethod = shootingmethod
        self.description = description
    }

    public var displayLabel: String {
        if let smalltext, !smalltext.isEmpty { return smalltext }
        return code
    }
}
