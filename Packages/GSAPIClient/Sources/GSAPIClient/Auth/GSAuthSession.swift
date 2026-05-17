import Foundation
import Observation
import GSCore

// MARK: - GSAccessToken (extended)

extension GSAccessToken {
    /// HTTP header value to send on authenticated requests.
    /// Grand Shooting accepts either standard `Bearer` or its legacy
    /// `access_token` scheme — we pick based on how the token was obtained.
    public var authorizationHeaderValue: String {
        switch scheme {
        case .bearer: return "Bearer \(token)"
        case .accessToken: return "access_token \(token)"
        }
    }
}

// MARK: - GSAuthSession

/// Single source of truth for the current access token. Both the legacy
/// hand-rolled `LiveGSAPI` and the generated `Client` resolve their token
/// through this actor, so a single sign-in covers all API calls.
public actor GSAuthSession {
    public static let shared = GSAuthSession()

    private static let tokenKeychainKey = "current-access-token"

    private var cached: GSAccessToken?

    private init() {
        self.cached = Self.loadFromKeychain()
    }

    public func currentToken() -> GSAccessToken? {
        cached
    }

    public func setToken(_ token: GSAccessToken?) {
        cached = token
        if let token, let data = try? JSONEncoder().encode(token), let str = String(data: data, encoding: .utf8) {
            try? GSKeychain.set(str, forKey: Self.tokenKeychainKey)
        } else {
            GSKeychain.delete(Self.tokenKeychainKey)
        }
    }

    private static func loadFromKeychain() -> GSAccessToken? {
        guard let str = GSKeychain.get(tokenKeychainKey),
              let data = str.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(GSAccessToken.self, from: data)
    }
}

// MARK: - AuthState (UI binding)

/// `@Observable` wrapper exposed to SwiftUI. The view layer reads
/// `isAuthenticated` to gate access; sign-in / sign-out mutate the
/// underlying `GSAuthSession.shared`.
@Observable
@MainActor
public final class AuthState {
    public private(set) var token: GSAccessToken?

    public var isAuthenticated: Bool { token != nil }

    public init() {
        // Synchronous read of the keychain via a fresh decode — avoids
        // crossing the actor boundary at init time.
        if let str = GSKeychain.get("current-access-token"),
           let data = str.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(GSAccessToken.self, from: data) {
            self.token = decoded
        }
    }

    public func signIn(_ token: GSAccessToken) async {
        self.token = token
        await GSAuthSession.shared.setToken(token)
    }

    public func signOut() async {
        self.token = nil
        await GSAuthSession.shared.setToken(nil)
    }
}
