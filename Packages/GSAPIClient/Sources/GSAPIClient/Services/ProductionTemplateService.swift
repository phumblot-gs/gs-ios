import Foundation
import GSCore

/// Reads the production templates configured on the GS account. The
/// user optionally picks one in Settings; its ID is then passed as
/// `template_id` when the tech-views flow creates a production so the
/// production inherits the template's configuration.
public struct ProductionTemplateService: Sendable {
    private let http: GSHTTPClient

    public init(environment: GSEnvironment) {
        self.http = GSHTTPClient(environment: environment)
    }

    public func list() async throws -> [ProductionTemplate] {
        try await http.get("/production/template", as: [ProductionTemplate].self)
    }
}
