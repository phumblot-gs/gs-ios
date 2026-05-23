import Foundation
import GSCore

/// Drives the **post-WebAuth** half of the OAuth dance:
///
///   1. Parse the `session_id` out of the deep-link callback URL.
///   2. POST to `/auth/exchange` to swap the session id for an access /
///      refresh token pair (the backend has the `client_secret`).
///   3. Persist both halves via `GSAuthSession.shared`.
///   4. Update `DevSettings.gsAPIShard` from the backend-supplied tenant
///      base URL so subsequent GS API calls land on the right shard.
///
/// The WebAuthenticationSession itself runs in the SwiftUI layer so we can
/// use the iOS 17+ `\.webAuthenticationSession` environment value. Once it
/// returns the callback URL, this service finishes the job.
public struct OAuthSignInService: Sendable {

    public struct SignInResult: Sendable {
        public let token: GSAccessToken
        /// Email of the authenticated user, as reported by the
        /// OAuth backend. Nil when the backend doesn't include it
        /// (older deployments); callers should treat that case as
        /// "non-staff" — i.e. force production, hide dev knobs.
        public let email: String?
    }

    public enum SignInError: Error, Sendable {
        case missingSessionId
        case backend(OAuthBackendService.OAuthError)
    }

    private let environment: GSEnvironment
    private let backend: OAuthBackendService

    public init(environment: GSEnvironment) {
        self.environment = environment
        self.backend = OAuthBackendService(environment: environment)
    }

    public func completeSignIn(callbackURL: URL) async throws -> SignInResult {
        let sessionId = try Self.parseSessionId(from: callbackURL)
        return try await completeSignIn(sessionId: sessionId)
    }

    public func completeSignIn(sessionId: String) async throws -> SignInResult {
        let response: OAuthBackendService.ExchangeResponse
        do {
            response = try await backend.exchange(sessionId: sessionId)
        } catch let err as OAuthBackendService.OAuthError {
            throw SignInError.backend(err)
        }

        let expiresAt = response.expires_in.map { Date().addingTimeInterval(Double($0)) }
        let token = GSAccessToken(
            token: response.access_token,
            scheme: .accessToken,
            expiresAt: expiresAt
        )
        await GSAuthSession.shared.setOAuthSession(
            accessToken: token,
            refreshToken: response.refresh_token
        )

        // Side-effect: if the backend told us the tenant shard, persist it
        // so future API calls go to the right host.
        if let apiBase = response.api_base_url,
           let host = URL(string: apiBase)?.host,
           let shard = host.split(separator: ".").first.map(String.init) {
            await MainActor.run {
                DevSettings.shared.gsAPIShard = shard
            }
        }

        return SignInResult(token: token, email: response.email)
    }

    private static func parseSessionId(from url: URL) throws -> String {
        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let sessionId = components.queryItems?.first(where: { $0.name == "session_id" })?.value,
            !sessionId.isEmpty
        else {
            throw SignInError.missingSessionId
        }
        return sessionId
    }
}
