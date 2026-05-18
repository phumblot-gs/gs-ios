import Foundation

/// Mock authentication for the dev build. Validates a fixed set of credentials
/// (`test` / `test2026`) and flips the app's `AuthState` to signed-in.
///
/// **Note on API token**: this service does NOT take a bearer token. The
/// token is configured separately in the Settings tab (post sign-in) and
/// resolved at API-call time by `GSAuthSession.shared.currentToken()`.
/// Decoupling sign-in from API token means the user can use the scanner UI
/// without setting up a key, and the API call site shows a clear "Configure
/// API key" hint instead of hard-blocking the flow.
public struct MockAuthService: Sendable {
    public static let acceptedUsername = "test"
    public static let acceptedPassword = "test2026"

    public enum SignInError: Error, Sendable {
        case invalidCredentials
    }

    public init() {}

    public func signIn(username: String, password: String) throws {
        guard username == Self.acceptedUsername,
              password == Self.acceptedPassword else {
            throw SignInError.invalidCredentials
        }
    }
}
