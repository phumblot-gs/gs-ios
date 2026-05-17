import Foundation
import GSCore

/// High-level wrapper around the auto-generated `Client.getReference(...)`.
/// Returns plain Swift arrays so call sites don't need to handle the
/// generated `Operations.getReference.Output` enum.
public actor ReferenceService {
    private let client: Client

    public init(client: Client) {
        self.client = client
    }

    /// Convenience initialiser that builds a `Client` for the given
    /// environment, plumbed to `GSAuthSession.shared` for tokens.
    public init(environment: GSEnvironment) {
        self.client = GSGeneratedClient.make(
            environment: environment,
            tokenProvider: { await GSAuthSession.shared.currentToken() }
        )
    }

    public enum LookupError: Error, Sendable {
        case notFound
        case http(status: Int)
        case transport(any Error)
    }

    /// Look up a reference by EAN. The Grand Shooting endpoint always
    /// returns HTTP 200 with a (possibly empty) array — empty means
    /// "no match", not a transport error.
    public func lookupByEAN(_ ean: String) async throws -> [Components.Schemas.Reference] {
        do {
            let output = try await client.getReference(query: .init(ean: ean))
            switch output {
            case .ok(let ok):
                let array = try ok.body.json
                return array
            case .undocumented(let status, _):
                throw LookupError.http(status: status)
            }
        } catch let lookup as LookupError {
            throw lookup
        } catch {
            throw LookupError.transport(error)
        }
    }
}
