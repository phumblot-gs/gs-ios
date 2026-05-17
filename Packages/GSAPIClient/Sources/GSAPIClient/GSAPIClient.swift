import Foundation
import GSCore

// MARK: - Auth Token

/// An access token used to authenticate API calls.
///
/// Two schemes are supported because the Grand Shooting API accepts both:
/// - `.bearer` → `Authorization: Bearer <token>` (standard, used by the
///   dev mock and by personal API keys).
/// - `.accessToken` → `Authorization: access_token <token>` (GS legacy
///   scheme, used after the OAuth dance).
public struct GSAccessToken: Sendable, Hashable, Codable {
    public enum Scheme: String, Sendable, Hashable, Codable {
        case bearer
        case accessToken
    }

    public let token: String
    public let scheme: Scheme
    public let expiresAt: Date?

    public init(token: String, scheme: Scheme = .accessToken, expiresAt: Date? = nil) {
        self.token = token
        self.scheme = scheme
        self.expiresAt = expiresAt
    }
}

// MARK: - Errors

public enum GSAPIError: Error, Sendable {
    case notAuthenticated
    case transport(URLError)
    case http(status: Int, body: Data?)
    case decoding(Error)
    case unknown
}

// MARK: - Protocol

/// Public interface for all backend calls. UI layers and use-cases consume this
/// protocol so tests can swap in `MockGSAPI`.
public protocol GSAPIProtocol: Sendable {
    var environment: GSEnvironment { get }

    func setAccessToken(_ token: GSAccessToken?) async

    // Samples
    func fetchSample(barcode: String) async throws -> Sample
    func receiveSample(_ sample: Sample) async throws -> Sample

    // Shipments
    func createShipment(_ shipment: Shipment) async throws -> Shipment

    // Generic — useful while the OpenAPI codegen pipeline is still TODO.
    func get<T: Decodable & Sendable>(_ path: String, as type: T.Type) async throws -> T
    func post<Body: Encodable & Sendable, Response: Decodable & Sendable>(
        _ path: String,
        body: Body,
        as type: Response.Type
    ) async throws -> Response
}

// MARK: - Live implementation

public actor LiveGSAPI: GSAPIProtocol {
    public nonisolated let environment: GSEnvironment

    private let session: URLSession
    private let logger = GSLogger(category: "GSAPIClient")
    private var accessToken: GSAccessToken?

    public init(environment: GSEnvironment, session: URLSession = .shared) {
        self.environment = environment
        self.session = session
    }

    public func setAccessToken(_ token: GSAccessToken?) {
        self.accessToken = token
    }

    // TODO: replace these hand-rolled calls with generated client from
    //       swift-openapi-generator once `bin/regenerate-api.sh` is wired up.

    public func fetchSample(barcode: String) async throws -> Sample {
        try await get("/samples/\(barcode)", as: Sample.self)
    }

    public func receiveSample(_ sample: Sample) async throws -> Sample {
        try await post("/samples/receive", body: sample, as: Sample.self)
    }

    public func createShipment(_ shipment: Shipment) async throws -> Shipment {
        try await post("/shipments", body: shipment, as: Shipment.self)
    }

    public func get<T: Decodable & Sendable>(_ path: String, as type: T.Type) async throws -> T {
        let request = try makeRequest(path: path, method: "GET", body: nil as Data?)
        return try await perform(request)
    }

    public func post<Body: Encodable & Sendable, Response: Decodable & Sendable>(
        _ path: String,
        body: Body,
        as type: Response.Type
    ) async throws -> Response {
        let data = try JSONEncoder.gs.encode(body)
        let request = try makeRequest(path: path, method: "POST", body: data)
        return try await perform(request)
    }

    // MARK: - Helpers

    private func makeRequest(path: String, method: String, body: Data?) throws -> URLRequest {
        let url = environment.apiBaseURL.appendingPathComponent(path.trimmingLeadingSlash)
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = accessToken {
            req.setValue(token.authorizationHeaderValue, forHTTPHeaderField: "Authorization")
        }
        req.httpBody = body
        return req
    }

    private func perform<T: Decodable & Sendable>(_ request: URLRequest) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            throw GSAPIError.transport(urlError)
        } catch {
            throw GSAPIError.unknown
        }

        guard let http = response as? HTTPURLResponse else {
            throw GSAPIError.unknown
        }
        guard (200..<300).contains(http.statusCode) else {
            logger.error("HTTP \(http.statusCode) for \(request.url?.absoluteString ?? "?")")
            throw GSAPIError.http(status: http.statusCode, body: data)
        }

        do {
            return try JSONDecoder.gs.decode(T.self, from: data)
        } catch {
            throw GSAPIError.decoding(error)
        }
    }
}

// MARK: - Mock implementation

public actor MockGSAPI: GSAPIProtocol {
    public nonisolated let environment: GSEnvironment

    public var stubbedSample: Sample?
    public var receivedCalls: [String] = []

    public init(environment: GSEnvironment = .placeholder) {
        self.environment = environment
    }

    public func setAccessToken(_ token: GSAccessToken?) {
        receivedCalls.append("setAccessToken")
    }

    public func fetchSample(barcode: String) async throws -> Sample {
        receivedCalls.append("fetchSample(\(barcode))")
        return stubbedSample ?? Sample(barcode: barcode)
    }

    public func receiveSample(_ sample: Sample) async throws -> Sample {
        receivedCalls.append("receiveSample(\(sample.barcode))")
        return sample
    }

    public func createShipment(_ shipment: Shipment) async throws -> Shipment {
        receivedCalls.append("createShipment")
        return shipment
    }

    public func get<T: Decodable & Sendable>(_ path: String, as type: T.Type) async throws -> T {
        receivedCalls.append("GET \(path)")
        throw GSAPIError.unknown
    }

    public func post<Body: Encodable & Sendable, Response: Decodable & Sendable>(
        _ path: String,
        body: Body,
        as type: Response.Type
    ) async throws -> Response {
        receivedCalls.append("POST \(path)")
        throw GSAPIError.unknown
    }
}

// MARK: - JSON coders

extension JSONEncoder {
    static let gs: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

extension JSONDecoder {
    static let gs: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

private extension String {
    var trimmingLeadingSlash: String {
        hasPrefix("/") ? String(dropFirst()) : self
    }
}
