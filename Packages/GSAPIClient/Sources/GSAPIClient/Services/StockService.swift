import Foundation
import GSCore

/// GS API surface for stock items (`/stock`, `/stock/:id`).
public struct StockService: Sendable {

    /// Which `Reference` attribute to use as the lookup key when a barcode
    /// is scanned. Configurable in Settings — `.ean` is the default but
    /// some accounts use `.ref` as the barcode value.
    public enum SearchAttribute: String, Sendable, Codable, CaseIterable {
        case ean
        case ref

        public var displayName: String {
            switch self {
            case .ean: return String(localized: "EAN")
            case .ref: return String(localized: "Reference (ref)")
            }
        }
    }

    private let http: GSHTTPClient

    public init(environment: GSEnvironment) {
        self.http = GSHTTPClient(environment: environment)
    }

    // MARK: - Lookup

    /// Lookup a stock item (and its parent reference) by scanned value.
    /// Returns every `ReferenceStock` matching the value, which may contain
    /// zero, one, or several stock_items.
    public func search(scannedValue: String, by attribute: SearchAttribute) async throws -> [ReferenceStock] {
        let key: String
        switch attribute {
        case .ean: key = "ean"
        case .ref: key = "ref"
        }
        return try await http.get("/stock", query: [key: scannedValue], as: [ReferenceStock].self)
    }

    /// One page of stock items within a batch.
    public func page(batchID: Int, offset: Int = 0) async throws -> (items: [ReferenceStock], pagination: PaginationInfo) {
        try await http.getPage(
            "/stock",
            query: ["batch_id": String(batchID)],
            offset: offset,
            as: ReferenceStock.self
        )
    }

    // MARK: - Create

    /// Matches the GS `Model75` schema for `POST /stock`. `reference_id` and
    /// `stock_item_status` are required by the server; the rest are
    /// optional. We deliberately do NOT send `ref` — the schema doesn't
    /// declare it and we've seen GS reject the payload when it's present.
    public struct CreatePayload: Encodable, Sendable {
        public let reference_id: Int
        public let stock_item_status: Int
        public let batch_id: Int?
        public let ean: String?
        public let smalltext: String?

        public init(
            referenceID: Int,
            batchID: Int?,
            status: StockItemStatus,
            ean: String? = nil,
            smalltext: String? = nil
        ) {
            self.reference_id = referenceID
            self.stock_item_status = status.rawValue
            self.batch_id = batchID
            self.ean = ean
            self.smalltext = smalltext
        }
    }

    public func create(_ payload: CreatePayload) async throws -> StockItem {
        try await http.post("/stock", body: payload, as: StockItem.self)
    }

    // MARK: - Update

    public struct UpdatePayload: Encodable, Sendable {
        public let stock_item_status: Int?
        public let batch_id: Int?
        public let smalltext: String?
        public let ean: String?
        public let star: Bool?

        public init(
            status: StockItemStatus? = nil,
            batchID: Int? = nil,
            smalltext: String? = nil,
            ean: String? = nil,
            star: Bool? = nil
        ) {
            self.stock_item_status = status?.rawValue
            self.batch_id = batchID
            self.smalltext = smalltext
            self.ean = ean
            self.star = star
        }
    }

    public func update(id: Int, payload: UpdatePayload) async throws -> StockItem {
        try await http.patch("/stock/\(id)", body: payload, as: StockItem.self)
    }
}
