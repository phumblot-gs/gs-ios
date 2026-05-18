import Foundation
import Observation
import GSCore

/// Per-device dev configuration: which Grand Shooting tenant shard to talk
/// to, which mobile-backend environment to point at, and the personal API
/// key used for the mock-auth fallback.
///
/// - Shard + env live in `UserDefaults` (non-sensitive, sync-friendly).
/// - API key lives in the Keychain (sensitive).
///
/// Reactive: SwiftUI views can observe this via `@Bindable` / `@Observable`.
@Observable
@MainActor
public final class DevSettings {

    public static let shared = DevSettings()

    public enum BackendEnvironment: String, CaseIterable, Sendable, Codable {
        case staging
        case production

        public var displayName: String {
            switch self {
            case .staging: return "Staging"
            case .production: return "Production"
            }
        }

        public var mobileBackendURL: URL {
            switch self {
            case .staging:
                return URL(string: "https://api-staging.mobile.grand-shooting.com")!
            case .production:
                return URL(string: "https://api.mobile.grand-shooting.com")!
            }
        }
    }

    // MARK: - Stored values

    public var gsAPIShard: String {
        didSet {
            UserDefaults.standard.set(gsAPIShard, forKey: Self.shardKey)
        }
    }

    public var backendEnvironment: BackendEnvironment {
        didSet {
            UserDefaults.standard.set(backendEnvironment.rawValue, forKey: Self.envKey)
        }
    }

    // Trigger token (incremented on apiKey changes) so views observing
    // DevSettings re-render their "configured ✓ / missing" indicators
    // even though the API key itself lives in the Keychain.
    public private(set) var apiKeyRevision: Int = 0

    public var apiKey: String? {
        get { GSKeychain.get(Self.apiKeyKey) }
        set {
            if let value = newValue, !value.isEmpty {
                try? GSKeychain.set(value, forKey: Self.apiKeyKey)
            } else {
                GSKeychain.delete(Self.apiKeyKey)
            }
            apiKeyRevision &+= 1
        }
    }

    public var hasAPIKey: Bool { apiKey != nil }

    // MARK: - Derived

    /// Build a `GSEnvironment` from the current settings.
    public var currentEnvironment: GSEnvironment {
        let api = URL(string: "https://\(gsAPIShard).grand-shooting.com/v3")
            ?? URL(string: "https://api-19.grand-shooting.com/v3")!
        return GSEnvironment(
            apiBaseURL: api,
            mobileBackendBaseURL: backendEnvironment.mobileBackendURL
        )
    }

    // MARK: - Init

    private init() {
        self.gsAPIShard = UserDefaults.standard.string(forKey: Self.shardKey)
            ?? "api-19"
        let raw = UserDefaults.standard.string(forKey: Self.envKey) ?? "staging"
        self.backendEnvironment = BackendEnvironment(rawValue: raw) ?? .staging
    }

    // MARK: - UserDefaults / Keychain keys

    private static let shardKey = "dev.gs.shard"
    private static let envKey = "dev.backend.environment"
    private static let apiKeyKey = "dev.gs.api-key"
}
