import Foundation
import GSCore

/// Uploads a single photo into a Grand Shooting production via
/// `POST /production/:bench_root_id/bench/:bench_root_id/upload`.
/// The path takes the production's `root_id` twice — the upper
/// production root and the bench root — for historical reasons in
/// the GS routing.
public struct ProductionUploadService: Sendable {
    private let http: GSHTTPClient

    public init(environment: GSEnvironment) {
        self.http = GSHTTPClient(environment: environment)
    }

    /// Upload `jpegData` under `filename` to the production identified
    /// by `productionRootID`. Returns whatever JSON the server hands
    /// back (we don't decode it; an empty success is the common case).
    public func upload(
        jpegData: Data,
        filename: String,
        productionRootID: Int
    ) async throws {
        let part = GSHTTPClient.MultipartPart(
            name: "file",
            filename: filename,
            contentType: "image/jpeg",
            data: jpegData
        )
        let _: EmptyResponse = try await http.postMultipart(
            "/production/\(productionRootID)/bench/\(productionRootID)/upload",
            parts: [part],
            as: EmptyResponse.self
        )
    }
}
