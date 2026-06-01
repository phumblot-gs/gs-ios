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

    public enum MeasurementUnit: String, CaseIterable, Sendable, Codable {
        case centimeters
        case inches

        public var displayName: String {
            switch self {
            case .centimeters: return String(localized: "Centimeters")
            case .inches: return String(localized: "Inches")
            }
        }

        /// API symbol stored in `extra.measures.<name>.unit`.
        public var apiSymbol: String {
            switch self {
            case .centimeters: return "cm"
            case .inches: return "in"
            }
        }

        public func convert(meters: Double) -> Double {
            switch self {
            case .centimeters: return meters * 100
            case .inches: return meters * 39.3700787
            }
        }
    }

    public enum LanguagePreference: String, CaseIterable, Sendable, Codable {
        case system
        case en
        case fr
        case pl

        public var displayName: String {
            switch self {
            case .system: return String(localized: "System")
            case .en: return "English"
            case .fr: return "Français"
            case .pl: return "Polski"
            }
        }

        /// BCP-47 / Apple locale identifier to push to
        /// `AppleLanguages` so SwiftUI's String(localized:) and
        /// `Bundle.main.localizedString(...)` pick the matching
        /// .lproj / xcstrings entry. Returns nil for `.system`
        /// (we let UIKit fall back to the OS default).
        public var localeIdentifier: String? {
            switch self {
            case .system: return nil
            case .en: return "en"
            case .fr: return "fr"
            case .pl: return "pl"
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

    // MARK: - GS accounts (multi-account selector)

    /// Every account the authenticated user can access, from
    /// `/account/me`. Persisted so the Profile selector can render
    /// before the next `/me` round-trip.
    public private(set) var accounts: [AccountInfo] = []

    /// The user's home account (`me.account_id`). Its shard is the
    /// **default shard** used for `/stock*` calls regardless of the
    /// account selector.
    public private(set) var defaultAccountID: Int?

    /// The account currently selected in Profile. Drives the shard +
    /// `account_id` header for every non-`/stock` call, and the
    /// namespace all per-account settings persist under. Nil before
    /// the first `/account/me`.
    public private(set) var activeAccountID: Int?

    /// Shard host token (e.g. `api-16`) of the default account, kept
    /// so `/stock*` keeps targeting it even when the selector points
    /// elsewhere.
    private var defaultAPIShard: String?

    /// Account ids the user has selected, most-recent first. Drives
    /// the "recent" shortcuts in the account picker. Capped; deduped.
    public private(set) var recentAccountIDs: [Int] = []

    /// Account ids the user has **enabled** (chosen in Profile) and can
    /// switch the active account between (from the Scan tab). Seeded
    /// with the home account on first `/account/me`; never empty (the
    /// home account is forced back in if everything is disabled).
    public private(set) var enabledAccountIDs: Set<Int> = []

    /// The enabled accounts, in the order they appear in `accounts`.
    public var enabledAccounts: [AccountInfo] {
        accounts.filter { enabledAccountIDs.contains($0.accountID) }
    }

    /// Custom catalog columns of the active account
    /// (`prefs.catalog_extra_cols`), filtered to the displayable ones.
    public var activeCatalogExtraColumns: [CatalogExtraColumn] {
        (accounts.first { $0.accountID == activeAccountID }?.catalogExtraColumns ?? [])
            .filter(\.isDisplayable)
    }

    /// Replaces the enabled set (from the Profile multi-select), keeps
    /// the home account enabled when the user clears everything, then
    /// reconciles the active account so it stays within the set.
    public func setEnabledAccounts(_ ids: Set<Int>) {
        enabledAccountIDs = ids
        if enabledAccountIDs.isEmpty, let home = defaultAccountID {
            enabledAccountIDs = [home]
        }
        persistEnabledAccounts()
        reconcileActiveAccount()
    }

    /// The account that should be active given the enabled set: the
    /// current one if still valid, else the home account, else the
    /// first enabled account, else the home account as a last resort.
    public func resolvedActiveAccountID() -> Int? {
        let existing = Set(accounts.map(\.accountID))
        if let active = activeAccountID, enabledAccountIDs.contains(active), existing.contains(active) {
            return active
        }
        if let home = defaultAccountID, enabledAccountIDs.contains(home) {
            return home
        }
        return accounts.map(\.accountID).first { enabledAccountIDs.contains($0) } ?? defaultAccountID
    }

    /// Re-applies the active account if it has drifted out of the
    /// enabled set. Returns true when the active account changed.
    @discardableResult
    public func reconcileActiveAccount() -> Bool {
        let target = resolvedActiveAccountID()
        guard target != activeAccountID else { return false }
        applyActiveAccount(target)
        return true
    }

    private func persistEnabledAccounts() {
        UserDefaults.standard.set(Array(enabledAccountIDs).sorted(), forKey: Self.enabledAccountIDsKey)
    }

    /// Store the accounts list + the user's home account from
    /// `/account/me`. Migrates the legacy (pre-multi-account) flat
    /// settings into the home namespace once, so an updating user
    /// keeps their existing config. Does not change the active
    /// selection — call `applyActiveAccount` for that.
    public func setAccounts(_ list: [AccountInfo], defaultAccountID newDefault: Int?) {
        accounts = list
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: Self.accountsKey)
        }
        defaultAccountID = newDefault
        if let newDefault {
            UserDefaults.standard.set(newDefault, forKey: Self.defaultAccountIDKey)
            if let host = list.first(where: { $0.accountID == newDefault })?.apiHost,
               let shard = Self.shard(fromHost: host) {
                defaultAPIShard = shard
                UserDefaults.standard.set(shard, forKey: Self.defaultAPIShardKey)
            }
            migrateLegacyIfNeeded(into: newDefault)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.defaultAccountIDKey)
        }
        // Seed the enabled set with the home account on first run,
        // then prune it to accounts that still exist. The home account
        // is forced back in if pruning emptied the set.
        let existing = Set(list.map(\.accountID))
        if enabledAccountIDs.isEmpty, let home = newDefault {
            enabledAccountIDs = [home]
        }
        enabledAccountIDs.formIntersection(existing)
        if enabledAccountIDs.isEmpty, let home = newDefault {
            enabledAccountIDs = [home]
        }
        persistEnabledAccounts()
    }

    /// Switch the active account: repoint the active shard from the
    /// account's `api_host`, send its id as the `account_id` header,
    /// and reload every per-account setting from that account's
    /// namespace. Persisted so it survives relaunch.
    public func applyActiveAccount(_ id: Int?) {
        activeAccountID = id
        if let id {
            UserDefaults.standard.set(id, forKey: Self.activeAccountIDKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.activeAccountIDKey)
        }
        if let id,
           let host = accounts.first(where: { $0.accountID == id })?.apiHost,
           let shard = Self.shard(fromHost: host) {
            gsAPIShard = shard
        }
        if let id {
            var recents = recentAccountIDs.filter { $0 != id }
            recents.insert(id, at: 0)
            recentAccountIDs = Array(recents.prefix(10))
            UserDefaults.standard.set(recentAccountIDs, forKey: Self.recentAccountIDsKey)
        }
        loadAccountScopedSettings()
    }

    /// One-time copy of the pre-multi-account flat settings into
    /// `id`'s namespace, so an updating user's existing config lands
    /// on their home account. No-op once the per-account marker is set.
    private func migrateLegacyIfNeeded(into id: Int) {
        let marker = "acct.\(id).migrated"
        let d = UserDefaults.standard
        guard !d.bool(forKey: marker) else { return }
        for base in Self.perAccountKeys {
            let target = Self.nsKey(base, account: id)
            if d.object(forKey: target) == nil, let legacy = d.object(forKey: base) {
                d.set(legacy, forKey: target)
            }
        }
        d.set(true, forKey: marker)
    }

    /// Namespaces a per-account UserDefaults key by the active account.
    /// Before any account is applied (no `/me` yet) the bare key is
    /// used, so behaviour matches the pre-multi-account build — those
    /// values then migrate into the home namespace on first apply.
    private static func nsKey(_ base: String, account: Int?) -> String {
        guard let account else { return base }
        return "acct.\(account).\(base)"
    }

    /// `https://api-34.grand-shooting.com` → `api-34`.
    private static func shard(fromHost host: String) -> String? {
        let h = URL(string: host)?.host ?? host
        return h.split(separator: ".").first.map(String.init)
    }

    // MARK: - Scan / workflow preferences

    /// The studio zone the user is working from. Single value (one fixed
    /// zone per session), persisted across launches. `nil` when the account
    /// has no zones or before the user makes a choice. GS identifies zones
    /// by their label string, not a numeric id — hence `String?`.
    public var activeZone: String? = nil {
        didSet {
            if let id = activeZone {
                UserDefaults.standard.set(id, forKey: Self.nsKey(Self.activeZoneKey, account: activeAccountID))
            } else {
                UserDefaults.standard.removeObject(forKey: Self.nsKey(Self.activeZoneKey, account: activeAccountID))
            }
        }
    }

    /// Status values offered in the Change Status UI for a stock item.
    /// Defaults to "all 15 enabled". The user can disable a subset in
    /// Settings; the default-on-register value is force-enabled (we can't
    /// register a stock item with a disabled default).
    public var enabledStockItemStatuses: Set<Int> = [] {
        didSet {
            let array = Array(enabledStockItemStatuses).sorted()
            UserDefaults.standard.set(array, forKey: Self.nsKey(Self.enabledStatusesKey, account: activeAccountID))
        }
    }

    /// What `stock_item_status` value newly-created stock items get when
    /// using the "Register a product" flow.
    public var defaultStockItemStatusOnRegister: Int = 0 {
        didSet {
            UserDefaults.standard.set(defaultStockItemStatusOnRegister, forKey: Self.nsKey(Self.defaultStatusOnRegisterKey, account: activeAccountID))
            // Force-include the default in the enabled set.
            enabledStockItemStatuses.insert(defaultStockItemStatusOnRegister)
        }
    }

    /// Status applied to the picked stock_item when the user taps the
    /// "Next" button on the tech-views capture screen. Per-account so
    /// each account can have its own end-of-tech-views state.
    public var defaultStockItemStatusAfterTechViews: Int = 0 {
        didSet {
            UserDefaults.standard.set(defaultStockItemStatusAfterTechViews, forKey: Self.nsKey(Self.defaultStatusAfterTechViewsKey, account: activeAccountID))
        }
    }

    /// Known batch types, seeded at app startup from `BatchService.sampleTypes()`
    /// and editable in Settings.
    public var batchTypes: [String] = [] {
        didSet { UserDefaults.standard.set(batchTypes, forKey: Self.nsKey(Self.batchTypesKey, account: activeAccountID)) }
    }

    /// Which `Reference` attribute (ean or ref) is treated as the barcode
    /// value when the user scans a *product* (not a batch).
    public var searchAttribute: StockService.SearchAttribute = .ean {
        didSet { UserDefaults.standard.set(searchAttribute.rawValue, forKey: Self.nsKey(Self.searchAttributeKey, account: activeAccountID)) }
    }

    public var languagePreference: LanguagePreference {
        didSet { UserDefaults.standard.set(languagePreference.rawValue, forKey: Self.languageKey) }
    }

    public var measurementUnit: MeasurementUnit {
        didSet { UserDefaults.standard.set(measurementUnit.rawValue, forKey: Self.measurementUnitKey) }
    }

    /// Minimum delay (seconds) enforced between two barcode scans —
    /// including before the first scan when the scanner appears.
    /// Applied uniformly to every scanner surface (Scan products,
    /// Register products, Batch scan, etc.). Global, not per-account.
    public var scannerCooldownSeconds: Double {
        didSet { UserDefaults.standard.set(scannerCooldownSeconds, forKey: Self.scannerCooldownKey) }
    }

    /// Stock-item status ids the user wants visible in the batch
    /// detail filter. Persisted device-wide so the choice carries
    /// across batches. `nil` → no explicit choice (show all enabled
    /// statuses). Global, not per-account: stock always lives on the
    /// home account.
    public var batchStatusFilter: Set<Int>? {
        didSet {
            if let filter = batchStatusFilter {
                UserDefaults.standard.set(Array(filter).sorted(), forKey: Self.batchStatusFilterKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.batchStatusFilterKey)
            }
        }
    }

    // MARK: - Technical views

    /// How the capture screen picks its starting mode (presentation
    /// vs OCR) when the user enters the photo flow for a new
    /// reference.
    public enum CapturePersistence: String, Sendable, CaseIterable, Codable {
        case alwaysPresentation
        case rememberLast
    }

    public var techViewsCapturePersistence: CapturePersistence = .alwaysPresentation {
        didSet { UserDefaults.standard.set(techViewsCapturePersistence.rawValue, forKey: Self.nsKey(Self.capturePersistenceKey, account: activeAccountID)) }
    }

    /// Whether the OCR capture mode runs the Vision text + picto
    /// pipelines after a shot. When off, the OCR mode still
    /// uploads the photo (under the OCR filename pattern) but
    /// skips the annotation step entirely — useful on devices
    /// where Vision is slow or unreliable.
    public var isOCREnabled: Bool = false {
        didSet { UserDefaults.standard.set(isOCREnabled, forKey: Self.nsKey(Self.ocrEnabledKey, account: activeAccountID)) }
    }

    /// Whether the LiDAR-based Measure flow is available. When
    /// off, the Measures section routes to a plain photo capture
    /// (using the Measurement filename pattern) instead of the
    /// AR placement UI. Defaults to true only on devices that
    /// actually have a LiDAR sensor.
    public var isMeasureEnabled: Bool = false {
        didSet { UserDefaults.standard.set(isMeasureEnabled, forKey: Self.nsKey(Self.measureEnabledKey, account: activeAccountID)) }
    }

    /// Raw value of the last `CaptureMode` the user actively used.
    /// Honoured only when `techViewsCapturePersistence == .rememberLast`.
    public var techViewsLastCaptureModeRaw: String? = nil {
        didSet {
            if let raw = techViewsLastCaptureModeRaw {
                UserDefaults.standard.set(raw, forKey: Self.nsKey(Self.lastCaptureModeKey, account: activeAccountID))
            } else {
                UserDefaults.standard.removeObject(forKey: Self.nsKey(Self.lastCaptureModeKey, account: activeAccountID))
            }
        }
    }

    /// Raw value of `PresentationWhiteBalance` (the Presentation
    /// mode's white-balance behaviour — auto or a fixed Kelvin
    /// preset). Defaults to `"auto"`.
    public var techViewsWhiteBalanceRaw: String = "auto" {
        didSet { UserDefaults.standard.set(techViewsWhiteBalanceRaw, forKey: Self.nsKey(Self.whiteBalanceKey, account: activeAccountID)) }
    }

    /// Raw value of `PresentationColorProfile` (the curated
    /// colour-grading preset applied to Presentation captures).
    /// Defaults to `"none"`.
    public var techViewsColorProfileRaw: String = "none" {
        didSet { UserDefaults.standard.set(techViewsColorProfileRaw, forKey: Self.nsKey(Self.colorProfileKey, account: activeAccountID)) }
    }

    /// Raw value of `PresentationColorSpace` — the ICC profile
    /// tagged onto Presentation / Detail JPEGs after capture.
    /// Defaults to `"sRGB"` (the international standard).
    public var techViewsColorSpaceRaw: String = "sRGB" {
        didSet { UserDefaults.standard.set(techViewsColorSpaceRaw, forKey: Self.nsKey(Self.colorSpaceKey, account: activeAccountID)) }
    }

    /// 35mm-equivalent focal length for Presentation captures.
    /// 70 mm is a moderately compressed portrait/product focal
    /// — neutral perspective, no wide-angle distortion.
    public var techViewsPresentationFocal: Int = 70 {
        didSet { UserDefaults.standard.set(techViewsPresentationFocal, forKey: Self.nsKey(Self.presentationFocalKey, account: activeAccountID)) }
    }

    /// 35mm-equivalent focal length for Detail captures. 100 mm
    /// gives a typical macro / portrait-detail compression while
    /// keeping the iPhone's close-focus capability.
    public var techViewsDetailFocal: Int = 100 {
        didSet { UserDefaults.standard.set(techViewsDetailFocal, forKey: Self.nsKey(Self.detailFocalKey, account: activeAccountID)) }
    }

    /// 35mm-equivalent focal length for OCR captures. Defaults to
    /// 13 mm so the lens selection lands on the ultra-wide sensor
    /// when available — its ~2 cm minimum focus is what lets the
    /// user read tiny labels right up close.
    public var techViewsOCRFocal: Int = 13 {
        didSet { UserDefaults.standard.set(techViewsOCRFocal, forKey: Self.nsKey(Self.ocrFocalKey, account: activeAccountID)) }
    }

    /// Filename template for **Presentation**-mode tech-view
    /// photos. Supports the placeholders `{EAN}`, `{REF}` and
    /// `{INC}` (1-based counter seeded from today's GS production).
    /// Default: `{EAN}_Article_{INC}.jpg`.
    public var photoFilenamePresentationPattern: String = DevSettings.defaultPresentationFilenamePattern {
        didSet { UserDefaults.standard.set(photoFilenamePresentationPattern, forKey: Self.nsKey(Self.presentationPatternKey, account: activeAccountID)) }
    }

    /// Filename template for **Detail**-mode tech-view photos.
    /// Default: `{EAN}_Detail_{INC}.jpg`.
    public var photoFilenameDetailPattern: String = DevSettings.defaultDetailFilenamePattern {
        didSet { UserDefaults.standard.set(photoFilenameDetailPattern, forKey: Self.nsKey(Self.detailPatternKey, account: activeAccountID)) }
    }

    /// Filename template for **OCR**-mode tech-view photos.
    /// Default: `{EAN}_Label_{INC}.jpg`.
    public var photoFilenameOCRPattern: String = DevSettings.defaultOCRFilenamePattern {
        didSet { UserDefaults.standard.set(photoFilenameOCRPattern, forKey: Self.nsKey(Self.ocrPatternKey, account: activeAccountID)) }
    }

    /// Filename template for measurement illustrations uploaded
    /// alongside `extra.measures`. Same placeholders as the
    /// tech-view templates. Default: `{EAN}_Measurement_{INC}.jpg`.
    public var photoFilenameMeasurePattern: String = DevSettings.defaultMeasureFilenamePattern {
        didSet { UserDefaults.standard.set(photoFilenameMeasurePattern, forKey: Self.nsKey(Self.measurePatternKey, account: activeAccountID)) }
    }

    public static let defaultPresentationFilenamePattern = "{EAN}_Article_{INC}.jpg"
    public static let defaultDetailFilenamePattern = "{EAN}_Detail_{INC}.jpg"
    public static let defaultOCRFilenamePattern = "{EAN}_Label_{INC}.jpg"
    public static let defaultMeasureFilenamePattern = "{EAN}_Measurement_{INC}.jpg"

    /// Renders a filename template using the given identifiers.
    /// Missing EAN falls back to the catalog `ref`, which is
    /// always present. `inc` is the 1-based counter the caller
    /// increments per upload. Pure (no state access) so callers
    /// in any isolation context can use it directly.
    nonisolated public static func renderFilename(
        template: String,
        ean: String?,
        ref: String,
        inc: Int
    ) -> String {
        let eanValue: String = {
            if let ean, !ean.trimmingCharacters(in: .whitespaces).isEmpty { return ean }
            return ref
        }()
        return template
            .replacingOccurrences(of: "{EAN}", with: eanValue)
            .replacingOccurrences(of: "{REF}", with: ref)
            .replacingOccurrences(of: "{INC}", with: String(inc))
    }

    /// Shooting method the technical-views uploads are scoped to.
    /// Required: the Photo tab is gated on this being non-nil.
    public var techViewsShootingMethodID: Int? = nil {
        didSet {
            if let id = techViewsShootingMethodID {
                UserDefaults.standard.set(id, forKey: Self.nsKey(Self.techViewsShootingMethodIDKey, account: activeAccountID))
            } else {
                UserDefaults.standard.removeObject(forKey: Self.nsKey(Self.techViewsShootingMethodIDKey, account: activeAccountID))
            }
        }
    }

    /// Display name cached alongside the ID so Settings can render
    /// the current selection without re-hitting `/shootingmethod`.
    public var techViewsShootingMethodName: String? = nil {
        didSet {
            if let name = techViewsShootingMethodName {
                UserDefaults.standard.set(name, forKey: Self.nsKey(Self.techViewsShootingMethodNameKey, account: activeAccountID))
            } else {
                UserDefaults.standard.removeObject(forKey: Self.nsKey(Self.techViewsShootingMethodNameKey, account: activeAccountID))
            }
        }
    }

    /// Production template the tech-views flow stamps onto
    /// newly-created productions via `template_id`. Optional: when
    /// nil, productions are created without a template (no
    /// `template_id` in the payload).
    public var techViewsTemplateID: Int? = nil {
        didSet {
            if let id = techViewsTemplateID {
                UserDefaults.standard.set(id, forKey: Self.nsKey(Self.techViewsTemplateIDKey, account: activeAccountID))
            } else {
                UserDefaults.standard.removeObject(forKey: Self.nsKey(Self.techViewsTemplateIDKey, account: activeAccountID))
            }
        }
    }

    /// Display name cached alongside the template ID so Settings can
    /// render the current selection without re-hitting
    /// `/production/template`.
    public var techViewsTemplateName: String? = nil {
        didSet {
            if let name = techViewsTemplateName {
                UserDefaults.standard.set(name, forKey: Self.nsKey(Self.techViewsTemplateNameKey, account: activeAccountID))
            } else {
                UserDefaults.standard.removeObject(forKey: Self.nsKey(Self.techViewsTemplateNameKey, account: activeAccountID))
            }
        }
    }

    /// JSON-encoded ordered list of `{id, visible}` describing which
    /// reference attributes show in the reference/stock-item info block
    /// and in what order. Per-account (the available extra columns
    /// differ per account). `nil` → use the built-in default order.
    public var referenceAttributeConfigJSON: String? = nil {
        didSet {
            if let json = referenceAttributeConfigJSON {
                UserDefaults.standard.set(json, forKey: Self.nsKey(Self.referenceAttributeConfigKey, account: activeAccountID))
            } else {
                UserDefaults.standard.removeObject(forKey: Self.nsKey(Self.referenceAttributeConfigKey, account: activeAccountID))
            }
        }
    }

    // MARK: - Derived

    /// True when the active account has BOTH a shooting method and a
    /// template configured — the two settings a GS production needs to
    /// accept photo uploads. Photo-capture flows that upload to GS are
    /// gated on this (a missing template lands the upload on the wrong
    /// bench, e.g. "cannot upload on validation bench").
    public var canUploadPhotosToGS: Bool {
        techViewsShootingMethodID != nil && techViewsTemplateID != nil
    }

    public var currentEnvironment: GSEnvironment {
        let api = URL(string: "https://\(gsAPIShard).grand-shooting.com/v3")
            ?? URL(string: "https://api-19.grand-shooting.com/v3")!
        // `/stock*` and `/account*` always target the user's principal
        // (home) shard. Only carry a distinct base when the selector
        // points at a different account's shard.
        let principalBase: URL? = {
            guard let defaultAPIShard, defaultAPIShard != gsAPIShard else { return nil }
            return URL(string: "https://\(defaultAPIShard).grand-shooting.com/v3")
        }()
        return GSEnvironment(
            apiBaseURL: api,
            mobileBackendBaseURL: backendEnvironment.mobileBackendURL,
            principalAPIBaseURL: principalBase,
            accountIDHeader: activeAccountID,
            principalAccountID: defaultAccountID
        )
    }

    // MARK: - Init

    private init() {
        self.gsAPIShard = UserDefaults.standard.string(forKey: Self.shardKey) ?? "api-19"
        // Default to production for fresh installs — the staging
        // backend is staff-only and a normal user should never hit
        // it. Staff can flip back via the long-press easter egg on
        // the login screen (or via Settings once signed in).
        let envRaw = UserDefaults.standard.string(forKey: Self.envKey) ?? "production"
        self.backendEnvironment = BackendEnvironment(rawValue: envRaw) ?? .production

        // Multi-account globals (never namespaced).
        if let data = UserDefaults.standard.data(forKey: Self.accountsKey),
           let decoded = try? JSONDecoder().decode([AccountInfo].self, from: data) {
            self.accounts = decoded
        }
        self.activeAccountID = UserDefaults.standard.object(forKey: Self.activeAccountIDKey) as? Int
        self.defaultAccountID = UserDefaults.standard.object(forKey: Self.defaultAccountIDKey) as? Int
        self.defaultAPIShard = UserDefaults.standard.string(forKey: Self.defaultAPIShardKey)
        self.recentAccountIDs = (UserDefaults.standard.array(forKey: Self.recentAccountIDsKey) as? [Int]) ?? []
        self.enabledAccountIDs = Set((UserDefaults.standard.array(forKey: Self.enabledAccountIDsKey) as? [Int]) ?? [])

        // Global UI preferences (device-level, shared across accounts).
        let langRaw = UserDefaults.standard.string(forKey: Self.languageKey) ?? "system"
        self.languagePreference = LanguagePreference(rawValue: langRaw) ?? .system

        let unitRaw = UserDefaults.standard.string(forKey: Self.measurementUnitKey) ?? "centimeters"
        self.measurementUnit = MeasurementUnit(rawValue: unitRaw) ?? .centimeters

        if UserDefaults.standard.object(forKey: Self.scannerCooldownKey) != nil {
            self.scannerCooldownSeconds = UserDefaults.standard.double(forKey: Self.scannerCooldownKey)
        } else {
            self.scannerCooldownSeconds = 2.0
        }

        if let storedFilter = UserDefaults.standard.array(forKey: Self.batchStatusFilterKey) as? [Int] {
            self.batchStatusFilter = Set(storedFilter)
        } else {
            self.batchStatusFilter = nil
        }

        // Every per-account setting loads from the active account's
        // namespace (or the bare keys before the first `/account/me`).
        loadAccountScopedSettings()
    }

    /// (Re)loads every per-account setting from the active account's
    /// UserDefaults namespace, applying defaults where absent. Called
    /// at init and whenever the active account changes. Assigning the
    /// properties here fires their `didSet`, re-persisting into the
    /// (now correct) namespace — harmless and keeps storage in sync.
    private func loadAccountScopedSettings() {
        let d = UserDefaults.standard
        func key(_ base: String) -> String { Self.nsKey(base, account: activeAccountID) }

        activeZone = d.string(forKey: key(Self.activeZoneKey))

        let allStatuses: Set<Int> = Set(StockItemStatus.allCases.map(\.rawValue))
        if let stored = d.array(forKey: key(Self.enabledStatusesKey)) as? [Int], !stored.isEmpty {
            enabledStockItemStatuses = Set(stored)
        } else {
            enabledStockItemStatuses = allStatuses
        }

        if d.object(forKey: key(Self.defaultStatusOnRegisterKey)) != nil {
            defaultStockItemStatusOnRegister = d.integer(forKey: key(Self.defaultStatusOnRegisterKey))
        } else {
            defaultStockItemStatusOnRegister = StockItemStatus.addToStock.rawValue
        }

        if d.object(forKey: key(Self.defaultStatusAfterTechViewsKey)) != nil {
            defaultStockItemStatusAfterTechViews = d.integer(forKey: key(Self.defaultStatusAfterTechViewsKey))
        } else {
            defaultStockItemStatusAfterTechViews = StockItemStatus.addToStock.rawValue
        }

        batchTypes = d.stringArray(forKey: key(Self.batchTypesKey)) ?? []

        let searchRaw = d.string(forKey: key(Self.searchAttributeKey)) ?? "ean"
        searchAttribute = StockService.SearchAttribute(rawValue: searchRaw) ?? .ean

        if d.object(forKey: key(Self.techViewsShootingMethodIDKey)) != nil {
            let raw = d.integer(forKey: key(Self.techViewsShootingMethodIDKey))
            techViewsShootingMethodID = raw == 0 ? nil : raw
        } else {
            techViewsShootingMethodID = nil
        }
        techViewsShootingMethodName = d.string(forKey: key(Self.techViewsShootingMethodNameKey))

        if d.object(forKey: key(Self.techViewsTemplateIDKey)) != nil {
            let raw = d.integer(forKey: key(Self.techViewsTemplateIDKey))
            techViewsTemplateID = raw == 0 ? nil : raw
        } else {
            techViewsTemplateID = nil
        }
        techViewsTemplateName = d.string(forKey: key(Self.techViewsTemplateNameKey))
        referenceAttributeConfigJSON = d.string(forKey: key(Self.referenceAttributeConfigKey))

        let persistenceRaw = d.string(forKey: key(Self.capturePersistenceKey))
            ?? CapturePersistence.alwaysPresentation.rawValue
        techViewsCapturePersistence = CapturePersistence(rawValue: persistenceRaw) ?? .alwaysPresentation

        // Feature toggles: `object(forKey:)` distinguishes "never set"
        // (off by default) from an explicit choice. Both ship disabled;
        // the user opts in from Settings → Photo once they want them.
        if let ocr = d.object(forKey: key(Self.ocrEnabledKey)) as? Bool {
            isOCREnabled = ocr
        } else {
            isOCREnabled = false
        }
        if let measure = d.object(forKey: key(Self.measureEnabledKey)) as? Bool {
            isMeasureEnabled = measure
        } else {
            isMeasureEnabled = false
        }

        techViewsLastCaptureModeRaw = d.string(forKey: key(Self.lastCaptureModeKey))
        techViewsWhiteBalanceRaw = d.string(forKey: key(Self.whiteBalanceKey)) ?? "auto"
        techViewsColorProfileRaw = d.string(forKey: key(Self.colorProfileKey)) ?? "none"
        techViewsColorSpaceRaw = d.string(forKey: key(Self.colorSpaceKey)) ?? "sRGB"

        let presentationFocal = d.integer(forKey: key(Self.presentationFocalKey))
        techViewsPresentationFocal = presentationFocal == 0 ? 70 : presentationFocal
        let detailFocal = d.integer(forKey: key(Self.detailFocalKey))
        techViewsDetailFocal = detailFocal == 0 ? 100 : detailFocal
        let ocrFocal = d.integer(forKey: key(Self.ocrFocalKey))
        techViewsOCRFocal = ocrFocal == 0 ? 13 : ocrFocal

        // Ultra-legacy single-pattern fallback only applies to the
        // bare-key (pre-account) read of the Presentation pattern.
        let legacyTechView = d.string(forKey: Self.legacyTechViewPatternKey)
        photoFilenamePresentationPattern = d.string(forKey: key(Self.presentationPatternKey))
            ?? legacyTechView
            ?? Self.defaultPresentationFilenamePattern
        photoFilenameDetailPattern = d.string(forKey: key(Self.detailPatternKey))
            ?? Self.defaultDetailFilenamePattern
        photoFilenameOCRPattern = d.string(forKey: key(Self.ocrPatternKey))
            ?? Self.defaultOCRFilenamePattern
        photoFilenameMeasurePattern = d.string(forKey: key(Self.measurePatternKey))
            ?? Self.defaultMeasureFilenamePattern

        // Safety net: the default-on-register status must always be
        // enabled, even if a persisted set excluded it.
        enabledStockItemStatuses.insert(defaultStockItemStatusOnRegister)
    }

    // MARK: - Keys

    private static let shardKey = "dev.gs.shard"
    private static let envKey = "dev.backend.environment"
    private static let apiKeyKey = "dev.gs.api-key"
    private static let activeZoneKey = "dev.zone.active"
    private static let enabledStatusesKey = "dev.stockStatuses.enabled"
    private static let defaultStatusOnRegisterKey = "dev.stockStatus.defaultOnRegister"
    private static let defaultStatusAfterTechViewsKey = "dev.stockStatus.defaultAfterTechViews"
    private static let batchTypesKey = "dev.batch.types"
    private static let searchAttributeKey = "dev.search.attribute"
    private static let languageKey = "dev.language.preferred"
    private static let measurementUnitKey = "dev.measurement.unit"
    private static let scannerCooldownKey = "dev.scanner.cooldownSeconds"
    private static let batchStatusFilterKey = "dev.batch.statusFilter"
    private static let techViewsShootingMethodIDKey = "dev.techViews.shootingMethodID"
    private static let techViewsShootingMethodNameKey = "dev.techViews.shootingMethodName"
    private static let techViewsTemplateIDKey = "dev.techViews.templateID"
    private static let techViewsTemplateNameKey = "dev.techViews.templateName"
    private static let referenceAttributeConfigKey = "dev.reference.attributeConfig"
    private static let capturePersistenceKey = "dev.techViews.capturePersistence"
    private static let ocrEnabledKey = "dev.features.ocrEnabled"
    private static let measureEnabledKey = "dev.features.measureEnabled"
    private static let lastCaptureModeKey = "dev.techViews.lastCaptureMode"
    private static let whiteBalanceKey = "dev.techViews.whiteBalance"
    private static let colorProfileKey = "dev.techViews.colorProfile"
    private static let colorSpaceKey = "dev.techViews.colorSpace"
    private static let presentationFocalKey = "dev.techViews.focal.presentation"
    private static let detailFocalKey = "dev.techViews.focal.detail"
    private static let ocrFocalKey = "dev.techViews.focal.ocr"
    private static let legacyTechViewPatternKey = "dev.photo.filename.techView"
    private static let presentationPatternKey = "dev.photo.filename.presentation"
    private static let detailPatternKey = "dev.photo.filename.detail"
    private static let ocrPatternKey = "dev.photo.filename.ocr"
    private static let measurePatternKey = "dev.photo.filename.measure"

    // Multi-account globals (never namespaced).
    private static let accountsKey = "acct.list"
    private static let activeAccountIDKey = "acct.active"
    private static let defaultAccountIDKey = "acct.default"
    private static let defaultAPIShardKey = "acct.defaultShard"
    private static let recentAccountIDsKey = "acct.recents"
    private static let enabledAccountIDsKey = "acct.enabled"

    /// Base keys whose values are stored per active account (via
    /// `nsKey`). Order is irrelevant; used by the legacy migration.
    private static let perAccountKeys: [String] = [
        activeZoneKey,
        enabledStatusesKey,
        defaultStatusOnRegisterKey,
        defaultStatusAfterTechViewsKey,
        batchTypesKey,
        searchAttributeKey,
        techViewsShootingMethodIDKey,
        techViewsShootingMethodNameKey,
        techViewsTemplateIDKey,
        techViewsTemplateNameKey,
        referenceAttributeConfigKey,
        capturePersistenceKey,
        ocrEnabledKey,
        measureEnabledKey,
        lastCaptureModeKey,
        whiteBalanceKey,
        colorProfileKey,
        colorSpaceKey,
        presentationFocalKey,
        detailFocalKey,
        ocrFocalKey,
        presentationPatternKey,
        detailPatternKey,
        ocrPatternKey,
        measurePatternKey
    ]
}
