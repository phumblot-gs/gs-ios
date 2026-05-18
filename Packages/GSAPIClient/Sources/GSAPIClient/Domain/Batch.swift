import Foundation

/// A logical grouping of stock items — a box, a shelf, a pallet. Optionally
/// linked to a `Zone`. The `code` attribute is a barcode the user can scan
/// to open the batch's contents directly.
public struct Batch: Sendable, Hashable, Identifiable, Codable {
    public let id: Int
    public let smalltext: String?
    public let code: String?
    public let type: String?
    public let zoneID: Int?
    public let dateCre: String?
    public let dateMod: String?

    public init(
        id: Int,
        smalltext: String? = nil,
        code: String? = nil,
        type: String? = nil,
        zoneID: Int? = nil,
        dateCre: String? = nil,
        dateMod: String? = nil
    ) {
        self.id = id
        self.smalltext = smalltext
        self.code = code
        self.type = type
        self.zoneID = zoneID
        self.dateCre = dateCre
        self.dateMod = dateMod
    }

    private enum CodingKeys: String, CodingKey {
        case id = "batch_id"
        case smalltext
        case code
        case type
        case zoneID = "zone_id"
        case dateCre = "date_cre"
        case dateMod = "date_mod"
    }

    public var displayName: String {
        if let smalltext, !smalltext.isEmpty { return smalltext }
        if let code, !code.isEmpty { return code }
        return "Batch #\(id)"
    }
}
