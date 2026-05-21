import Foundation
import GSCore

/// Reads the shooting methods configured on the GS account. The user
/// picks one in Settings to tell the app which production to attach
/// technical-views uploads to.
public struct ShootingMethodService: Sendable {
    private let http: GSHTTPClient

    public init(environment: GSEnvironment) {
        self.http = GSHTTPClient(environment: environment)
    }

    public func list() async throws -> [ShootingMethod] {
        try await http.get("/shootingmethod", as: [ShootingMethod].self)
    }
}
