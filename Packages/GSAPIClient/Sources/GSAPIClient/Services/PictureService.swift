import Foundation
import GSCore

/// GS API surface for pictures (`/picture`).
public struct PictureService: Sendable {
    private let http: GSHTTPClient

    public init(environment: GSEnvironment) {
        self.http = GSHTTPClient(environment: environment)
    }

    /// All pictures linked to the catalog reference `ref`. Per the GS
    /// spec, `reference_ref` is the param that matches against
    /// `Reference.ref`; the `ref` param filters on the value extracted
    /// *from* the picture itself, which is a different thing.
    /// Caller is expected to collapse the result via
    /// `[Picture].latestByFilePath()` before display.
    public func list(forRef ref: String) async throws -> [Picture] {
        try await http.get("/picture", query: ["reference_ref": ref], as: [Picture].self)
    }
}
