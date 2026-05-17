import Foundation
import GSCore
import GSAPIClient

// MARK: - Request / Response

public struct PackshotRequest: Sendable, Encodable {
    public let imageData: Data
    public let backgroundHint: String?

    public init(imageData: Data, backgroundHint: String? = nil) {
        self.imageData = imageData
        self.backgroundHint = backgroundHint
    }
}

public struct PackshotResponse: Sendable, Decodable {
    public let jobID: String
    public let resultURL: URL?
    public let status: String

    public init(jobID: String, resultURL: URL?, status: String) {
        self.jobID = jobID
        self.resultURL = resultURL
        self.status = status
    }
}

// MARK: - Protocol

public protocol PackshotService: Sendable {
    func generate(_ request: PackshotRequest) async throws -> PackshotResponse
}

// MARK: - Live

public actor LivePackshotService: PackshotService {
    private let api: GSAPIProtocol
    private let logger = GSLogger(category: "GSPackshot")

    public init(api: GSAPIProtocol) {
        self.api = api
    }

    public func generate(_ request: PackshotRequest) async throws -> PackshotResponse {
        logger.info("Submitting packshot job (\(request.imageData.count) bytes)")
        return try await api.post("/packshot", body: request, as: PackshotResponse.self)
    }
}

// MARK: - Mock

public actor MockPackshotService: PackshotService {
    public var stubbedResponse: PackshotResponse

    public init(
        stubbedResponse: PackshotResponse = PackshotResponse(
            jobID: "mock-job",
            resultURL: nil,
            status: "queued"
        )
    ) {
        self.stubbedResponse = stubbedResponse
    }

    public func generate(_ request: PackshotRequest) async throws -> PackshotResponse {
        stubbedResponse
    }
}
