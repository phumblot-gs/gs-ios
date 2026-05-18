import Foundation
import GSCore

/// New URLSession-based variant of the reference lookup. Coexists with the
/// existing `ReferenceService` (which goes through the generated
/// swift-openapi client) — we'll migrate everything onto this in time, but
/// for now both work. This one is needed because it shares the
/// `GSHTTPClient` plumbing (auth header, error mapping, paginated headers)
/// with the other domain services.
public struct ReferenceLookupService: Sendable {
    private let http: GSHTTPClient

    public init(environment: GSEnvironment) {
        self.http = GSHTTPClient(environment: environment)
    }

    /// Single-shot lookup by EAN or ref, depending on the configured
    /// search attribute.
    public func lookup(scannedValue: String, by attribute: StockService.SearchAttribute) async throws -> [Reference] {
        let key: String
        switch attribute {
        case .ean: key = "ean"
        case .ref: key = "ref"
        }
        return try await http.get("/reference", query: [key: scannedValue], as: [Reference].self)
    }

    /// Paginated search across multiple fields, used by the manual search
    /// view. Empty `query` returns the most recent references.
    public func searchPage(query: [String: String], offset: Int = 0) async throws -> (items: [Reference], pagination: PaginationInfo) {
        try await http.getPage("/reference", query: query, offset: offset, as: Reference.self)
    }
}
