import Foundation
import Observation
import GSCore

// MARK: - GSAccessToken (header rendering)

extension GSAccessToken {
    /// HTTP header value to send on authenticated requests.
    /// Grand Shooting accepts both standard `Bearer` (personal API keys) and
    /// its legacy `access_token` scheme (issued through OAuth) — we pick the
    /// scheme that matches how the token was obtained.
    public var authorizationHeaderValue: String {
        switch scheme {
        case .bearer: return "Bearer \(token)"
        case .accessToken: return "access_token \(token)"
        }
    }
}

// MARK: - GSAuthSession

/// Single source of truth for the **access token** used to authorise API
/// calls. Decoupled from `AuthState` (which only tracks whether the user has
/// signed into the app at all).
///
/// Token resolution order on every call:
///   1. OAuth-issued access token (once the GS plugin is wired). Stored on
///      this actor and persisted to the Keychain.
///   2. Personal API key from `DevSettings.shared.apiKey` (mock fallback,
///      used today). Wrapped on the fly as a `.bearer` token.
///   3. `nil` — no token; the call site is expected to short-circuit and
///      display a "Configure API key" hint instead of hitting the API.
public actor GSAuthSession {
    public static let shared = GSAuthSession()

    private static let tokenKeychainKey = "oauth-access-token"

    /// OAuth-acquired token. `nil` for now — the OAuth flow isn't wired yet.
    private var oauthToken: GSAccessToken?

    private init() {
        self.oauthToken = Self.loadFromKeychain()
    }

    public func currentToken() async -> GSAccessToken? {
        if let oauthToken { return oauthToken }
        // Fallback: the user's personal API key, if any.
        let apiKey = await MainActor.run { DevSettings.shared.apiKey }
        guard let apiKey, !apiKey.isEmpty else { return nil }
        return GSAccessToken(token: apiKey, scheme: .bearer)
    }

    /// Set or clear the OAuth-issued token. Called once OAuth is wired.
    public func setOAuthToken(_ token: GSAccessToken?) {
        oauthToken = token
        if let token, let data = try? JSONEncoder().encode(token),
           let str = String(data: data, encoding: .utf8) {
            try? GSKeychain.set(str, forKey: Self.tokenKeychainKey)
        } else {
            GSKeychain.delete(Self.tokenKeychainKey)
        }
    }

    /// True if any token can be resolved right now (OAuth or personal key).
    public func hasUsableToken() async -> Bool {
        await currentToken() != nil
    }

    private static func loadFromKeychain() -> GSAccessToken? {
        guard let str = GSKeychain.get(tokenKeychainKey),
              let data = str.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(GSAccessToken.self, from: data)
    }
}

// MARK: - AuthState (UI binding)

/// `@Observable` view-model exposed to SwiftUI. Tracks **whether the user is
/// signed in** as a UI gate. Decoupled from the API token: scanning works
/// regardless of token availability; the API call sites themselves check
/// `GSAuthSession.shared.currentToken()` and surface a clear message when
/// there's nothing to send.
@Observable
@MainActor
public final class AuthState {
    public private(set) var isSignedIn: Bool

    private static let signedInKey = "auth.signed-in"

    public init() {
        self.isSignedIn = UserDefaults.standard.bool(forKey: Self.signedInKey)
    }

    public func signIn() {
        isSignedIn = true
        UserDefaults.standard.set(true, forKey: Self.signedInKey)
    }

    public func signOut() async {
        isSignedIn = false
        UserDefaults.standard.set(false, forKey: Self.signedInKey)
        // Also wipe the OAuth token, if any. The personal API key in
        // DevSettings is preserved — the user explicitly stored it and
        // a sign-out doesn't imply they want it gone.
        await GSAuthSession.shared.setOAuthToken(nil)
    }
}
