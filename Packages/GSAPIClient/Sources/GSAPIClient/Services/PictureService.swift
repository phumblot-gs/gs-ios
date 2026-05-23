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

    /// Pictures uploaded under a specific shooting method for the
    /// catalog reference `ref`. Used by the tech-views gallery to
    /// only surface shots the user took from the technical-views
    /// capture flow (and not regular packshot views).
    ///
    /// - `shootingmethod` is filtered by **name** because the GS
    ///   `/picture` endpoint doesn't expose `shooting_method_id`
    ///   as a query argument.
    /// - `picturestatus=gte:10` keeps only stored / validated
    ///   pictures, dropping in-flight upload rows (statuses < 10
    ///   are the upload pipeline's transient states).
    /// - `sort_by=date_cre` returns newest-uploaded last; callers
    ///   may reverse if they want most-recent first.
    public func listTechViews(
        forRef ref: String,
        shootingMethodName: String,
        minStatus: Int = 10
    ) async throws -> [Picture] {
        try await http.get(
            "/picture",
            query: [
                "reference_ref": ref,
                "shootingmethod": shootingMethodName,
                "picturestatus": "gte:\(minStatus)",
                "sort_by": "date_cre"
            ],
            as: [Picture].self
        )
    }
}
