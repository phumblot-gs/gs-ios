import Foundation
import GSCore

/// Uploads photos attached directly to a catalog reference — currently
/// the reception photo captured right after registering a stock_item.
/// Hits `POST /reference/{reference_id}/photo/upload` with the JPEG as
/// a multipart `file` part. The active-account routing (selected shard
/// + `account_id` header) is applied automatically by `GSHTTPClient`
/// since the path doesn't start with `/stock`.
public struct ReferencePhotoService: Sendable {
    private let http: GSHTTPClient

    public init(environment: GSEnvironment) {
        self.http = GSHTTPClient(environment: environment)
    }

    public func uploadReceptionPhoto(
        referenceID: Int,
        jpegData: Data,
        filename: String
    ) async throws {
        let part = GSHTTPClient.MultipartPart(
            name: "file",
            filename: filename,
            contentType: "image/jpeg",
            data: jpegData
        )
        let _: EmptyResponse = try await http.postMultipart(
            "/reference/\(referenceID)/photo/upload",
            parts: [part],
            as: EmptyResponse.self
        )
    }
}
