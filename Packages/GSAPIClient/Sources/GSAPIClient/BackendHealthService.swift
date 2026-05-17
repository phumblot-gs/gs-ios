import Foundation
import GSCore

/// Pings the mobile-backend `/health` endpoint. Useful both for a connectivity
/// indicator in the UI and for catching configuration drift between iOS and
/// the deployed Lambda (env mismatch, custom-domain DNS issues, etc.).
public struct BackendHealthService: Sendable {

    public struct HealthResponse: Sendable, Codable {
        public let status: String
        public let service: String
        public let environment: String
        public let timestamp: String
    }

    public enum HealthError: Error, Sendable {
        case http(status: Int)
        case decoding(any Error)
        case transport(any Error)
    }

    private let environment: GSEnvironment
    private let session: URLSession

    public init(environment: GSEnvironment, session: URLSession = .shared) {
        self.environment = environment
        self.session = session
    }

    public func ping() async throws -> HealthResponse {
        var request = URLRequest(url: environment.healthURL)
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw HealthError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw HealthError.http(status: -1)
        }
        guard http.statusCode == 200 else {
            throw HealthError.http(status: http.statusCode)
        }

        do {
            return try JSONDecoder().decode(HealthResponse.self, from: data)
        } catch {
            throw HealthError.decoding(error)
        }
    }
}
