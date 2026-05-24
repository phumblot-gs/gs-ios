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

    // MARK: - Scan / workflow preferences

    /// The studio zone the user is working from. Single value (one fixed
    /// zone per session), persisted across launches. `nil` when the account
    /// has no zones or before the user makes a choice. GS identifies zones
    /// by their label string, not a numeric id — hence `String?`.
    public var activeZone: String? {
        didSet {
            if let id = activeZone {
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

    public var measurementUnit: MeasurementUnit {
        didSet { UserDefaults.standard.set(measurementUnit.rawValue, forKey: Self.measurementUnitKey) }
    }

    // MARK: - Technical views

    /// How the capture screen picks its starting mode (presentation
    /// vs OCR) when the user enters the photo flow for a new
    /// reference.
    public enum CapturePersistence: String, Sendable, CaseIterable, Codable {
        case alwaysPresentation
        case rememberLast
    }

    public var techViewsCapturePersistence: CapturePersistence {
        didSet { UserDefaults.standard.set(techViewsCapturePersistence.rawValue, forKey: Self.capturePersistenceKey) }
    }

    /// Whether the OCR capture mode runs the Vision text + picto
    /// pipelines after a shot. When off, the OCR mode still
    /// uploads the photo (under the OCR filename pattern) but
    /// skips the annotation step entirely — useful on devices
    /// where Vision is slow or unreliable.
    public var isOCREnabled: Bool {
        didSet { UserDefaults.standard.set(isOCREnabled, forKey: Self.ocrEnabledKey) }
    }

    /// Whether the LiDAR-based Measure flow is available. When
    /// off, the Measures section routes to a plain photo capture
    /// (using the Measurement filename pattern) instead of the
    /// AR placement UI. Defaults to true only on devices that
    /// actually have a LiDAR sensor.
    public var isMeasureEnabled: Bool {
        didSet { UserDefaults.standard.set(isMeasureEnabled, forKey: Self.measureEnabledKey) }
    }

    /// Raw value of the last `CaptureMode` the user actively used.
    /// Honoured only when `techViewsCapturePersistence == .rememberLast`.
    public var techViewsLastCaptureModeRaw: String? {
        didSet {
            if let raw = techViewsLastCaptureModeRaw {
                UserDefaults.standard.set(raw, forKey: Self.lastCaptureModeKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.lastCaptureModeKey)
            }
        }
    }

    /// Raw value of `PresentationWhiteBalance` (the Presentation
    /// mode's white-balance behaviour — auto or a fixed Kelvin
    /// preset). Defaults to `"auto"`.
    public var techViewsWhiteBalanceRaw: String {
        didSet { UserDefaults.standard.set(techViewsWhiteBalanceRaw, forKey: Self.whiteBalanceKey) }
    }

    /// Raw value of `PresentationColorProfile` (the curated
    /// colour-grading preset applied to Presentation captures).
    /// Defaults to `"none"`.
    public var techViewsColorProfileRaw: String {
        didSet { UserDefaults.standard.set(techViewsColorProfileRaw, forKey: Self.colorProfileKey) }
    }

    /// Raw value of `PresentationColorSpace` — the ICC profile
    /// tagged onto Presentation / Detail JPEGs after capture.
    /// Defaults to `"sRGB"` (the international standard).
    public var techViewsColorSpaceRaw: String {
        didSet { UserDefaults.standard.set(techViewsColorSpaceRaw, forKey: Self.colorSpaceKey) }
    }

    /// 35mm-equivalent focal length for Presentation captures.
    /// 70 mm is a moderately compressed portrait/product focal
    /// — neutral perspective, no wide-angle distortion.
    public var techViewsPresentationFocal: Int {
        didSet { UserDefaults.standard.set(techViewsPresentationFocal, forKey: Self.presentationFocalKey) }
    }

    /// 35mm-equivalent focal length for Detail captures. 100 mm
    /// gives a typical macro / portrait-detail compression while
    /// keeping the iPhone's close-focus capability.
    public var techViewsDetailFocal: Int {
        didSet { UserDefaults.standard.set(techViewsDetailFocal, forKey: Self.detailFocalKey) }
    }

    /// 35mm-equivalent focal length for OCR captures. Defaults to
    /// 13 mm so the lens selection lands on the ultra-wide sensor
    /// when available — its ~2 cm minimum focus is what lets the
    /// user read tiny labels right up close.
    public var techViewsOCRFocal: Int {
        didSet { UserDefaults.standard.set(techViewsOCRFocal, forKey: Self.ocrFocalKey) }
    }

    /// Filename template for **Presentation**-mode tech-view
    /// photos. Supports the placeholders `{EAN}`, `{REF}` and
    /// `{INC}` (1-based counter seeded from today's GS production).
    /// Default: `{EAN}_Article_{INC}.jpg`.
    public var photoFilenamePresentationPattern: String {
        didSet { UserDefaults.standard.set(photoFilenamePresentationPattern, forKey: Self.presentationPatternKey) }
    }

    /// Filename template for **Detail**-mode tech-view photos.
    /// Default: `{EAN}_Detail_{INC}.jpg`.
    public var photoFilenameDetailPattern: String {
        didSet { UserDefaults.standard.set(photoFilenameDetailPattern, forKey: Self.detailPatternKey) }
    }

    /// Filename template for **OCR**-mode tech-view photos.
    /// Default: `{EAN}_Label_{INC}.jpg`.
    public var photoFilenameOCRPattern: String {
        didSet { UserDefaults.standard.set(photoFilenameOCRPattern, forKey: Self.ocrPatternKey) }
    }

    /// Filename template for measurement illustrations uploaded
    /// alongside `extra.measures`. Same placeholders as the
    /// tech-view templates. Default: `{EAN}_Measurement_{INC}.jpg`.
    public var photoFilenameMeasurePattern: String {
        didSet { UserDefaults.standard.set(photoFilenameMeasurePattern, forKey: Self.measurePatternKey) }
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
    public var techViewsShootingMethodID: Int? {
        didSet {
            if let id = techViewsShootingMethodID {
                UserDefaults.standard.set(id, forKey: Self.techViewsShootingMethodIDKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.techViewsShootingMethodIDKey)
            }
        }
    }

    /// Display name cached alongside the ID so Settings can render
    /// the current selection without re-hitting `/shootingmethod`.
    public var techViewsShootingMethodName: String? {
        didSet {
            if let name = techViewsShootingMethodName {
                UserDefaults.standard.set(name, forKey: Self.techViewsShootingMethodNameKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.techViewsShootingMethodNameKey)
            }
        }
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
        // Default to production for fresh installs — the staging
        // backend is staff-only and a normal user should never hit
        // it. Staff can flip back via the long-press easter egg on
        // the login screen (or via Settings once signed in).
        let envRaw = UserDefaults.standard.string(forKey: Self.envKey) ?? "production"
        self.backendEnvironment = BackendEnvironment(rawValue: envRaw) ?? .production

        self.activeZone = UserDefaults.standard.string(forKey: Self.activeZoneKey)

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

        let unitRaw = UserDefaults.standard.string(forKey: Self.measurementUnitKey) ?? "centimeters"
        self.measurementUnit = MeasurementUnit(rawValue: unitRaw) ?? .centimeters

        if UserDefaults.standard.object(forKey: Self.techViewsShootingMethodIDKey) != nil {
            let raw = UserDefaults.standard.integer(forKey: Self.techViewsShootingMethodIDKey)
            self.techViewsShootingMethodID = raw == 0 ? nil : raw
        } else {
            self.techViewsShootingMethodID = nil
        }
        self.techViewsShootingMethodName = UserDefaults.standard.string(forKey: Self.techViewsShootingMethodNameKey)

        let persistenceRaw = UserDefaults.standard.string(forKey: Self.capturePersistenceKey)
            ?? CapturePersistence.alwaysPresentation.rawValue
        self.techViewsCapturePersistence = CapturePersistence(rawValue: persistenceRaw) ?? .alwaysPresentation

        // Feature toggles. Use UserDefaults `object(forKey:)` to
        // distinguish "never set" (use device-aware default) from
        // an explicit user choice. OCR defaults on (iOS 26 Vision
        // OCR is solid). Measure defaults to whether the device
        // actually has a LiDAR sensor.
        if let ocr = UserDefaults.standard.object(forKey: Self.ocrEnabledKey) as? Bool {
            self.isOCREnabled = ocr
        } else {
            self.isOCREnabled = true
        }
        if let measure = UserDefaults.standard.object(forKey: Self.measureEnabledKey) as? Bool {
            self.isMeasureEnabled = measure
        } else {
            // GSDeviceSupport is iOS-only (depends on ARKit/AVF).
            // On macOS unit-test builds the Measure flow doesn't
            // exist anyway, so default off.
            #if os(iOS)
            self.isMeasureEnabled = GSDeviceSupport.hasLiDAR
            #else
            self.isMeasureEnabled = false
            #endif
        }
        self.techViewsLastCaptureModeRaw = UserDefaults.standard.string(forKey: Self.lastCaptureModeKey)
        self.techViewsWhiteBalanceRaw = UserDefaults.standard.string(forKey: Self.whiteBalanceKey) ?? "auto"
        self.techViewsColorProfileRaw = UserDefaults.standard.string(forKey: Self.colorProfileKey) ?? "none"
        self.techViewsColorSpaceRaw = UserDefaults.standard.string(forKey: Self.colorSpaceKey) ?? "sRGB"

        let presentationFocal = UserDefaults.standard.integer(forKey: Self.presentationFocalKey)
        self.techViewsPresentationFocal = presentationFocal == 0 ? 70 : presentationFocal
        let detailFocal = UserDefaults.standard.integer(forKey: Self.detailFocalKey)
        self.techViewsDetailFocal = detailFocal == 0 ? 100 : detailFocal
        let ocrFocal = UserDefaults.standard.integer(forKey: Self.ocrFocalKey)
        self.techViewsOCRFocal = ocrFocal == 0 ? 13 : ocrFocal
        // Honour a previously-persisted single tech-view pattern
        // as the new Presentation default — that's where the
        // user's customisation most likely lived. Detail and OCR
        // fall back to their own dedicated defaults.
        let legacyTechView = UserDefaults.standard.string(forKey: Self.legacyTechViewPatternKey)
        self.photoFilenamePresentationPattern = UserDefaults.standard.string(forKey: Self.presentationPatternKey)
            ?? legacyTechView
            ?? Self.defaultPresentationFilenamePattern
        self.photoFilenameDetailPattern = UserDefaults.standard.string(forKey: Self.detailPatternKey)
            ?? Self.defaultDetailFilenamePattern
        self.photoFilenameOCRPattern = UserDefaults.standard.string(forKey: Self.ocrPatternKey)
            ?? Self.defaultOCRFilenamePattern
        self.photoFilenameMeasurePattern = UserDefaults.standard.string(forKey: Self.measurePatternKey)
            ?? Self.defaultMeasureFilenamePattern

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
    private static let measurementUnitKey = "dev.measurement.unit"
    private static let techViewsShootingMethodIDKey = "dev.techViews.shootingMethodID"
    private static let techViewsShootingMethodNameKey = "dev.techViews.shootingMethodName"
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
}
