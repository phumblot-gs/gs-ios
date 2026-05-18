import Foundation
import GSCore

/// GS API surface for shooting categories (`/specification/category`).
public struct CategoryService: Sendable {
    private let http: GSHTTPClient

    public init(environment: GSEnvironment) {
        self.http = GSHTTPClient(environment: environment)
    }

    /// All categories with their nested view_types. The catalog is small
    /// (a few dozen entries) — no pagination expected from the API.
    public func list() async throws -> [Category] {
        try await http.get("/specification/category", as: [Category].self)
    }
}
