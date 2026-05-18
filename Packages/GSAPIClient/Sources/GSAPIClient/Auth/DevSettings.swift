import Foundation
import Observation
import GSCore

/// Per-device dev configuration: GS tenant shard, mobile-backend env,
/// personal API key (mock-auth fallback), plus all the user-facing
/// preferences that drive the Scan flows (active zone, default stock_item
/// status, search attribute, etc.).
///
/// Non-sensitive values live in `UserDefaults`. The API key lives in the
/// Keychain.
///
/// Reactive: SwiftUI views observe via `@Bindable` / `@Observable`.
@Observable
@MainActor
public final class DevSettings {

    public static let shared = DevSettings()

    // MARK: - Nested types

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

    public enum LanguagePreference: String, CaseIterable, Sendable, Codable {
        case system
        case en
        case fr

        public var displayName: String {
            switch self {
            case .system: return String(localized: "System")
            case .en: return "English"
            case .fr: return "Français"
            }
        }
    }

    // MARK: - Backend

    public var gsAPIShard: String {
        didSet { UserDefaults.standard.set(gsAPIShard, forKey: Self.shardKey) }
    }

    public var backendEnvironment: BackendEnvironment {
        didSet { UserDefaults.standard.set(backendEnvironment.rawValue, forKey: Self.envKey) }
    }

    // MARK: - API key (Keychain)

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

    // MARK: - Scan / workflow preferences

    /// The studio zone the user is working from. Single value (one fixed
    /// zone per session), persisted across launches. `nil` when the account
    /// has no zones or before the user makes a choice.
    public var activeZoneID: Int? {
        didSet {
            if let id = activeZoneID {
                UserDefaults.standard.set(id, forKey: Self.activeZoneKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.activeZoneKey)
            }
        }
    }

    /// Status values offered in the Change Status UI for a stock item.
    /// Defaults to "all 15 enabled". The user can disable a subset in
    /// Settings; the default-on-register value is force-enabled (we can't
    /// register a stock item with a disabled default).
    public var enabledStockItemStatuses: Set<Int> {
        didSet {
            let array = Array(enabledStockItemStatuses).sorted()
            UserDefaults.standard.set(array, forKey: Self.enabledStatusesKey)
        }
    }

    /// What `stock_item_status` value newly-created stock items get when
    /// using the "Register a product" flow.
    public var defaultStockItemStatusOnRegister: Int {
        didSet {
            UserDefaults.standard.set(defaultStockItemStatusOnRegister, forKey: Self.defaultStatusOnRegisterKey)
            // Force-include the default in the enabled set.
            enabledStockItemStatuses.insert(defaultStockItemStatusOnRegister)
        }
    }

    /// Known batch types, seeded at app startup from `BatchService.sampleTypes()`
    /// and editable in Settings.
    public var batchTypes: [String] {
        didSet { UserDefaults.standard.set(batchTypes, forKey: Self.batchTypesKey) }
    }

    /// Which `Reference` attribute (ean or ref) is treated as the barcode
    /// value when the user scans a *product* (not a batch).
    public var searchAttribute: StockService.SearchAttribute {
        didSet { UserDefaults.standard.set(searchAttribute.rawValue, forKey: Self.searchAttributeKey) }
    }

    public var languagePreference: LanguagePreference {
        didSet { UserDefaults.standard.set(languagePreference.rawValue, forKey: Self.languageKey) }
    }

    // MARK: - Derived

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
        self.gsAPIShard = UserDefaults.standard.string(forKey: Self.shardKey) ?? "api-19"
        let envRaw = UserDefaults.standard.string(forKey: Self.envKey) ?? "staging"
        self.backendEnvironment = BackendEnvironment(rawValue: envRaw) ?? .staging

        if UserDefaults.standard.object(forKey: Self.activeZoneKey) != nil {
            self.activeZoneID = UserDefaults.standard.integer(forKey: Self.activeZoneKey)
        } else {
            self.activeZoneID = nil
        }

        let allStatuses: Set<Int> = Set(StockItemStatus.allCases.map(\.rawValue))
        if let stored = UserDefaults.standard.array(forKey: Self.enabledStatusesKey) as? [Int],
           !stored.isEmpty {
            self.enabledStockItemStatuses = Set(stored)
        } else {
            self.enabledStockItemStatuses = allStatuses
        }

        if UserDefaults.standard.object(forKey: Self.defaultStatusOnRegisterKey) != nil {
            self.defaultStockItemStatusOnRegister = UserDefaults.standard.integer(forKey: Self.defaultStatusOnRegisterKey)
        } else {
            self.defaultStockItemStatusOnRegister = StockItemStatus.addToStock.rawValue
        }

        self.batchTypes = UserDefaults.standard.stringArray(forKey: Self.batchTypesKey) ?? []

        let searchRaw = UserDefaults.standard.string(forKey: Self.searchAttributeKey) ?? "ean"
        self.searchAttribute = StockService.SearchAttribute(rawValue: searchRaw) ?? .ean

        let langRaw = UserDefaults.standard.string(forKey: Self.languageKey) ?? "system"
        self.languagePreference = LanguagePreference(rawValue: langRaw) ?? .system

        // Safety net: force the default-on-register status to be enabled,
        // even if the user previously persisted a list that excluded it.
        // Done at the end of init so every stored property is initialised.
        enabledStockItemStatuses.insert(defaultStockItemStatusOnRegister)
    }

    // MARK: - Keys

    private static let shardKey = "dev.gs.shard"
    private static let envKey = "dev.backend.environment"
    private static let apiKeyKey = "dev.gs.api-key"
    private static let activeZoneKey = "dev.zone.active"
    private static let enabledStatusesKey = "dev.stockStatuses.enabled"
    private static let defaultStatusOnRegisterKey = "dev.stockStatus.defaultOnRegister"
    private static let batchTypesKey = "dev.batch.types"
    private static let searchAttributeKey = "dev.search.attribute"
    private static let languageKey = "dev.language.preferred"
}
