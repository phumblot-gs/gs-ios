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

    /// True if the token has a known expiry and we're within 60 seconds of it.
    public var isExpiringSoon: Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSinceNow < 60
    }
}

// MARK: - GSAuthSession

/// Single source of truth for the **access token** used to authorise API
/// calls. Decoupled from `AuthState` (which only tracks whether the user has
/// signed into the app at all).
///
/// Token resolution order on every call:
///   1. OAuth-issued access token (real GS plugin flow). Stored on this
///      actor and persisted to the Keychain alongside its refresh token.
///   2. Personal API key from `DevSettings.shared.apiKey` (mock fallback).
///      Wrapped on the fly as a `.bearer` token.
///   3. `nil` — no token; the call site is expected to short-circuit.
public actor GSAuthSession {
    public static let shared = GSAuthSession()

    private static let accessKeychainKey = "oauth-access-token"
    private static let refreshKeychainKey = "oauth-refresh-token"

    private var oauthAccessToken: GSAccessToken?
    private var oauthRefreshToken: String?

    private init() {
        self.oauthAccessToken = Self.loadAccessFromKeychain()
        self.oauthRefreshToken = Self.loadRefreshFromKeychain()
    }

    public func currentToken() async -> GSAccessToken? {
        if let oauthAccessToken { return oauthAccessToken }
        let apiKey = await MainActor.run { DevSettings.shared.apiKey }
        guard let apiKey, !apiKey.isEmpty else { return nil }
        return GSAccessToken(token: apiKey, scheme: .bearer)
    }

    public func currentRefreshToken() -> String? {
        oauthRefreshToken
    }

    public func hasUsableToken() async -> Bool {
        await currentToken() != nil
    }

    /// Store the result of a fresh OAuth exchange. Persists both halves to
    /// the Keychain. Pass `nil` for both to clear the session entirely.
    public func setOAuthSession(
        accessToken: GSAccessToken?,
        refreshToken: String?
    ) {
        self.oauthAccessToken = accessToken
        self.oauthRefreshToken = refreshToken
        persist(access: accessToken)
        persist(refresh: refreshToken)
    }

    /// Replace just the access token (e.g. after a refresh response that
    /// didn't return a new refresh token). The previous refresh token is
    /// preserved.
    public func setOAuthAccessToken(_ token: GSAccessToken?) {
        self.oauthAccessToken = token
        persist(access: token)
    }

    public func clearOAuthSession() {
        setOAuthSession(accessToken: nil, refreshToken: nil)
    }

    // Back-compat for older call sites that only know about the access half.
    public func setOAuthToken(_ token: GSAccessToken?) {
        setOAuthAccessToken(token)
    }

    // MARK: - Persistence

    private static func loadAccessFromKeychain() -> GSAccessToken? {
        guard let str = GSKeychain.get(accessKeychainKey),
              let data = str.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(GSAccessToken.self, from: data)
    }

    private static func loadRefreshFromKeychain() -> String? {
        GSKeychain.get(refreshKeychainKey)
    }

    private func persist(access: GSAccessToken?) {
        if let access,
           let data = try? JSONEncoder().encode(access),
           let str = String(data: data, encoding: .utf8) {
            try? GSKeychain.set(str, forKey: Self.accessKeychainKey)
        } else {
            GSKeychain.delete(Self.accessKeychainKey)
        }
    }

    private func persist(refresh: String?) {
        if let refresh, !refresh.isEmpty {
            try? GSKeychain.set(refresh, forKey: Self.refreshKeychainKey)
        } else {
            GSKeychain.delete(Self.refreshKeychainKey)
        }
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
    /// Email of the signed-in user, as reported by the OAuth
    /// backend's `/auth/exchange` response. Drives `isGrandShootingStaff`,
    /// which gates the staging-environment picker in Settings.
    public private(set) var userEmail: String?

    private static let signedInKey = "auth.signed-in"
    private static let emailKey = "auth.user-email"
    private static let staffDomain = "grand-shooting.com"

    public init() {
        self.isSignedIn = UserDefaults.standard.bool(forKey: Self.signedInKey)
        self.userEmail = UserDefaults.standard.string(forKey: Self.emailKey)
    }

    public func signIn(email: String?) {
        isSignedIn = true
        userEmail = email
        UserDefaults.standard.set(true, forKey: Self.signedInKey)
        if let email, !email.isEmpty {
            UserDefaults.standard.set(email, forKey: Self.emailKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.emailKey)
        }
    }

    public func signOut() async {
        isSignedIn = false
        userEmail = nil
        UserDefaults.standard.set(false, forKey: Self.signedInKey)
        UserDefaults.standard.removeObject(forKey: Self.emailKey)
        await GSAuthSession.shared.clearOAuthSession()
    }

    /// True when the signed-in user's email belongs to the
    /// `@grand-shooting.com` domain — i.e. they're internal staff
    /// and can see / change dev-only knobs (notably the
    /// staging↔production backend switch). Outside callers should
    /// hide those controls when this is false and force the
    /// production environment.
    public var isGrandShootingStaff: Bool {
        guard let domain = userEmail?
            .split(separator: "@", maxSplits: 1, omittingEmptySubsequences: true)
            .last
            .map(String.init)?
            .lowercased()
        else { return false }
        return domain == Self.staffDomain
    }
}
