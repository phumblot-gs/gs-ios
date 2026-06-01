import Foundation
import GSCore

/// Partial-upsert on `POST /reference`. GS matches by `ref` (the
/// unique key in the active account's catalogue) and merges the
/// supplied attributes into the existing row — callers send only the
/// slice they want to update.
///
/// Used by the Register-product flow to stamp `online = today` on
/// every registration, regardless of whether the optional reception
/// photo step runs.
public struct ReferenceUpsertService: Sendable {

    private let http: GSHTTPClient

    public init(environment: GSEnvironment) {
        self.http = GSHTTPClient(environment: environment)
    }

    /// Stamp the reference's `online` field with `isoDate` (format
    /// `yyyy-MM-dd`, interpreted in the caller's local timezone by
    /// GS — same convention as the catalog). The response body is
    /// discarded; only success vs. failure matters.
    public func markOnline(ref: String, isoDate: String) async throws {
        let payload = OnlinePayload(ref: ref, online: isoDate)
        let _: EmptyResponse = try await http.post(
            "/reference",
            body: payload,
            as: EmptyResponse.self
        )
    }

    private struct OnlinePayload: Encodable, Sendable {
        let ref: String
        let online: String
    }
}
