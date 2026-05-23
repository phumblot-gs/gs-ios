import Foundation
import GSCore

/// HTTP client for the OAuth-proxy endpoints on our mobile backend
/// (`/auth/exchange`, `/auth/refresh`). These run on the Lambda backend
/// because the GS OAuth flow requires `client_secret`, which mustn't live
/// on-device.
public struct OAuthBackendService: Sendable {

    public struct ExchangeResponse: Sendable, Codable, Equatable {
        public let access_token: String
        public let refresh_token: String?
        public let expires_in: Int?
        /// Tenant API host returned by the backend, e.g. `https://api-19.grand-shooting.com`.
        /// When present, the client should switch `GSEnvironment.apiBaseURL` to
        /// this value so subsequent calls land on the right shard.
        public let api_base_url: String?
        /// Email of the authenticated user, as reported by the GS portal.
        /// Surfaced so the app can identify Grand-Shooting staff (their
        /// emails end in `@grand-shooting.com`) and gate dev-only UI like
        /// the staging-environment picker. Optional — older backend
        /// builds may not return it yet.
        public let email: String?
    }

    public enum OAuthError: Error, Sendable {
        case http(status: Int, body: String?)
        case decoding(any Error)
        case transport(any Error)
        case missingSessionId
    }

    private let environment: GSEnvironment
    private let session: URLSession

    public init(environment: GSEnvironment, session: URLSession = .shared) {
        self.environment = environment
        self.session = session
    }

    /// POST `/auth/exchange` — turns the one-shot `session_id` from the
    /// callback deep link into an actual access + refresh token pair.
    public func exchange(sessionId: String) async throws -> ExchangeResponse {
        let url = environment.mobileBackendBaseURL.appendingPathComponent("auth/exchange")
        return try await postJSON(url: url, body: ["session_id": sessionId])
    }

    /// POST `/auth/refresh` — swap a refresh token for a fresh access token.
    /// Must go through the backend because the refresh grant also requires
    /// the `client_secret`.
    public func refresh(refreshToken: String) async throws -> ExchangeResponse {
        let url = environment.mobileBackendBaseURL.appendingPathComponent("auth/refresh")
        return try await postJSON(url: url, body: ["refresh_token": refreshToken])
    }

    // MARK: - Plumbing

    private func postJSON(url: URL, body: [String: String]) async throws -> ExchangeResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        request.httpBody = try JSONEncoder().encode(body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw OAuthError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw OAuthError.http(status: -1, body: nil)
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8)
            throw OAuthError.http(status: http.statusCode, body: body)
        }
        do {
            return try JSONDecoder().decode(ExchangeResponse.self, from: data)
        } catch {
            throw OAuthError.decoding(error)
        }
    }
}
