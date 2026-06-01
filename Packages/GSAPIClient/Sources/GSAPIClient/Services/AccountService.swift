import Foundation
import GSCore

/// Reads the authenticated user's profile + accessible accounts via
/// `GET /account/me`. Drives the Profile header and the account
/// selector.
public struct AccountService: Sendable {
    private let http: GSHTTPClient

    public init(environment: GSEnvironment) {
        self.http = GSHTTPClient(environment: environment)
    }

    public func me() async throws -> AccountMe {
        try await http.get("/account/me", as: AccountMe.self)
    }
}
