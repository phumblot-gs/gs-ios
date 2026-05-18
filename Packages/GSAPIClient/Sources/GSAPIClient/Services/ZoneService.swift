import Foundation
import GSCore

/// GS API surface for storage zones (`/stock/zone`).
public struct ZoneService: Sendable {
    private let http: GSHTTPClient

    public init(environment: GSEnvironment) {
        self.http = GSHTTPClient(environment: environment)
    }

    /// All zones for the current account. The endpoint returns the full
    /// list — no pagination — but the response is small so that's fine.
    public func list() async throws -> [Zone] {
        try await http.get("/stock/zone", as: [Zone].self)
    }
}
