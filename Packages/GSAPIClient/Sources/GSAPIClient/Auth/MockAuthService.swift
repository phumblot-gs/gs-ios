import Foundation

/// Dev-only mock authentication. Lets the team test API-driven flows end-to-end
/// while the real Grand Shooting OAuth plugin (with `client_secret`) is being
/// provisioned.
///
/// **Security**: the bearer token is supplied by the caller — it MUST NOT be
/// hardcoded in source. The login UI takes the token as user input and stores
/// it in the Keychain through `GSAuthSession`. The token never appears in
/// the repository.
public struct MockAuthService: Sendable {
    public static let acceptedUsername = "test"
    public static let acceptedPassword = "test2026"

    public enum SignInError: Error, Sendable {
        case invalidCredentials
        case missingBearerToken
    }

    public init() {}

    /// Validates the dev credentials. On success the bearer token is wrapped
    /// in a `GSAccessToken` (scheme `.bearer`) and persisted via
    /// `GSAuthSession`.
    public func signIn(
        username: String,
        password: String,
        bearerToken: String
    ) async throws -> GSAccessToken {
        guard username == Self.acceptedUsername, password == Self.acceptedPassword else {
            throw SignInError.invalidCredentials
        }
        let trimmed = bearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SignInError.missingBearerToken
        }
        let token = GSAccessToken(token: trimmed, scheme: .bearer, expiresAt: nil)
        await GSAuthSession.shared.setToken(token)
        return token
    }
}
