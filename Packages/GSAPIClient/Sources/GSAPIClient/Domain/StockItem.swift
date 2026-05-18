import Foundation

/// A physical sample of a `Reference`. Multiple stock items can share the
/// same reference (e.g. one dress in S/M/L → three stock items). Each one
/// has its own status in the studio workflow.
public struct StockItem: Sendable, Hashable, Identifiable, Codable {
    public let id: Int
    public let batchID: Int?
    public let status: StockItemStatus
    public let smalltext: String?
    public let ean: String?
    public let star: Bool?
    public let dateCre: String?
    public let dateMod: String?

    public init(
        id: Int,
        batchID: Int?,
        status: StockItemStatus,
        smalltext: String? = nil,
        ean: String? = nil,
        star: Bool? = nil,
        dateCre: String? = nil,
        dateMod: String? = nil
    ) {
        self.id = id
        self.batchID = batchID
        self.status = status
        self.smalltext = smalltext
        self.ean = ean
        self.star = star
        self.dateCre = dateCre
        self.dateMod = dateMod
    }

    private enum CodingKeys: String, CodingKey {
        case id = "stock_item_id"
        case batchID = "batch_id"
        case status = "stock_item_status"
        case smalltext
        case ean
        case star
        case dateCre = "date_cre"
        case dateMod = "date_mod"
    }
}

/// What `GET /stock` returns: a reference with its embedded stock items.
public struct ReferenceStock: Sendable, Hashable, Codable {
    public let reference: Reference
    public let stockItems: [StockItem]

    public init(reference: Reference, stockItems: [StockItem]) {
        self.reference = reference
        self.stockItems = stockItems
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.stockItems = try container.decodeIfPresent([StockItem].self, forKey: .stockItems) ?? []
        // Reference fields are flat-merged into the same JSON object.
        self.reference = try Reference(from: decoder)
    }

    public func encode(to encoder: any Encoder) throws {
        try reference.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(stockItems, forKey: .stockItems)
    }

    private enum CodingKeys: String, CodingKey {
        case stockItems = "stock_items"
    }
}
