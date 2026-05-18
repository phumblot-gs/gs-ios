import Foundation
import GSCore

/// GS API surface for batches (`/stock/batch`).
public struct BatchService: Sendable {
    private let http: GSHTTPClient

    public init(environment: GSEnvironment) {
        self.http = GSHTTPClient(environment: environment)
    }

    // MARK: - List

    /// One page of batches starting at `offset`. Page size is decided by
    /// the server; `PaginationInfo` exposes what's left.
    public func page(offset: Int = 0, code: String? = nil) async throws -> (items: [Batch], pagination: PaginationInfo) {
        var query: [String: String] = [:]
        if let code, !code.isEmpty { query["code"] = code }
        return try await http.getPage("/stock/batch", query: query, offset: offset, as: Batch.self)
    }

    /// First-page sample used at app startup to seed
    /// `DevSettings.batchTypes` with the values the team actually uses.
    /// Distinct `type` values are returned ordered by frequency desc.
    public func sampleTypes() async throws -> [String] {
        let (items, _) = try await page(offset: 0)
        var counts: [String: Int] = [:]
        for batch in items {
            guard let type = batch.type, !type.isEmpty else { continue }
            counts[type, default: 0] += 1
        }
        return counts
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }
            .map(\.key)
    }

    // MARK: - Lookup by code (barcode scan)

    /// Resolve a batch by its `code` (the scanned barcode). Returns the
    /// first matching batch, or `nil` if none.
    public func find(byCode code: String) async throws -> Batch? {
        let (items, _) = try await page(offset: 0, code: code)
        return items.first { ($0.code ?? "") == code } ?? items.first
    }

    // MARK: - Create / update

    /// Body for `POST /stock/batch` and `POST /stock/batch/{id}` — they
    /// share the same `batch_modification`/`batch_creation` schema, both
    /// of which use `zone` (label string) rather than `zone_id`.
    public struct ModificationPayload: Encodable, Sendable {
        public let smalltext: String?
        public let code: String?
        public let type: String?
        public let zone: String?

        public init(smalltext: String?, code: String?, type: String?, zone: String?) {
            self.smalltext = smalltext
            self.code = code
            self.type = type
            self.zone = zone
        }
    }

    public typealias CreatePayload = ModificationPayload
    public typealias UpdatePayload = ModificationPayload

    public func create(_ payload: CreatePayload) async throws -> Batch {
        try await http.post("/stock/batch", body: payload, as: Batch.self)
    }

    /// GS uses POST (not PATCH) for batch updates — confirmed in
    /// `/stock/batch/{batch_id}` of the OpenAPI spec. PATCH yields a 405.
    public func update(id: Int, payload: UpdatePayload) async throws -> Batch {
        try await http.post("/stock/batch/\(id)", body: payload, as: Batch.self)
    }
}
