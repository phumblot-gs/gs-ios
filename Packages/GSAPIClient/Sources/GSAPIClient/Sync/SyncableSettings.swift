import Foundation
import GSCore

/// Bridges the per-account preferences in `DevSettings` to the opaque
/// JSON blob that travels through the Settings-Sync backend.
///
/// The set of "syncable" keys is intentionally narrow: workflow
/// preferences that an admin wants every operator on the same active
/// account to share (tech-views template, filename patterns, default
/// status flows, scan attribute, etc.). Device-level concerns (the
/// API shard, language, measurement unit, scanner cooldown, etc.) stay
/// local — they belong to the device, not the team.
///
/// Keep this list aligned with the Android `SyncableSettings.defaultBlob()`
/// when you want a blob written by one platform to be re-applied by the
/// other; the wire contract itself is platform-neutral.
@MainActor
public enum SyncableSettings {

    // MARK: - Key set (canonical names used in the blob)

    /// Blob keys are snake_case — the canonical wire schema shared with
    /// Android. Keep iOS aligned so a blob pushed by one platform is
    /// fully readable by the other; only the merge `unionForPush`
    /// guarantees forward-compat for unknown keys, and we want known
    /// keys to actually round-trip.
    public enum Key: String, CaseIterable, Sendable {
        case activeZone = "active_zone"
        case enabledStockItemStatuses = "enabled_stock_item_statuses"
        case defaultStockItemStatusOnRegister = "default_stock_item_status_on_register"
        case defaultStockItemStatusAfterTechViews = "default_stock_item_status_after_tech_views"
        case batchTypes = "batch_types"
        case searchAttribute = "search_attribute"
        case techViewsShootingMethodID = "tech_views_shooting_method_id"
        case techViewsShootingMethodName = "tech_views_shooting_method_name"
        case techViewsTemplateID = "tech_views_template_id"
        case techViewsTemplateName = "tech_views_template_name"
        case referenceAttributeConfigJSON = "reference_attribute_config"
        case techViewsCapturePersistence = "capture_persistence"
        case isOCREnabled = "ocr_enabled"
        case isMeasureEnabled = "measure_enabled"
        case techViewsWhiteBalanceRaw = "white_balance"
        case techViewsColorProfileRaw = "color_profile"
        case techViewsColorSpaceRaw = "color_space"
        case techViewsPresentationFocal = "focal_presentation"
        case techViewsDetailFocal = "focal_detail"
        case techViewsOCRFocal = "focal_ocr"
        case photoFilenamePresentationPattern = "pattern_presentation"
        case photoFilenameDetailPattern = "pattern_detail"
        case photoFilenameOCRPattern = "pattern_ocr"
        case photoFilenameMeasurePattern = "pattern_measure"
    }

    public static let knownKeys: Set<String> = Set(Key.allCases.map(\.rawValue))

    // MARK: - Default blob

    /// The "all-defaults" reference blob. Compared to the current
    /// blob to decide whether a push is meaningful (cf. spec §7
    /// "détection tous par défaut").
    public static func defaultBlob() -> [String: Any] {
        [
            Key.activeZone.rawValue: NSNull(),
            Key.enabledStockItemStatuses.rawValue: [Int](),
            Key.defaultStockItemStatusOnRegister.rawValue: 0,
            Key.defaultStockItemStatusAfterTechViews.rawValue: 0,
            Key.batchTypes.rawValue: [String](),
            Key.searchAttribute.rawValue: "ean",
            Key.techViewsShootingMethodID.rawValue: NSNull(),
            Key.techViewsShootingMethodName.rawValue: NSNull(),
            Key.techViewsTemplateID.rawValue: NSNull(),
            Key.techViewsTemplateName.rawValue: NSNull(),
            Key.referenceAttributeConfigJSON.rawValue: NSNull(),
            Key.techViewsCapturePersistence.rawValue: "alwaysPresentation",
            Key.isOCREnabled.rawValue: false,
            Key.isMeasureEnabled.rawValue: false,
            Key.techViewsWhiteBalanceRaw.rawValue: "auto",
            Key.techViewsColorProfileRaw.rawValue: "none",
            Key.techViewsColorSpaceRaw.rawValue: "sRGB",
            Key.techViewsPresentationFocal.rawValue: 70,
            Key.techViewsDetailFocal.rawValue: 100,
            Key.techViewsOCRFocal.rawValue: 13,
            Key.photoFilenamePresentationPattern.rawValue: "{EAN}_Article_{INC}.jpg",
            Key.photoFilenameDetailPattern.rawValue: "{EAN}_Detail_{INC}.jpg",
            Key.photoFilenameOCRPattern.rawValue: "{EAN}_Label_{INC}.jpg",
            Key.photoFilenameMeasurePattern.rawValue: "{EAN}_Measurement_{INC}.jpg"
        ]
    }

    // MARK: - Snapshot / Restore

    /// Snapshot the syncable subset of the active account's
    /// preferences as a JSON-ready dictionary. Output is suitable
    /// for canonicalisation + push.
    public static func snapshot(from settings: DevSettings) -> [String: Any] {
        var blob: [String: Any] = [:]

        blob[Key.activeZone.rawValue] = settings.activeZone as Any? ?? NSNull()
        blob[Key.enabledStockItemStatuses.rawValue] = Array(settings.enabledStockItemStatuses).sorted()
        blob[Key.defaultStockItemStatusOnRegister.rawValue] = settings.defaultStockItemStatusOnRegister
        blob[Key.defaultStockItemStatusAfterTechViews.rawValue] = settings.defaultStockItemStatusAfterTechViews
        blob[Key.batchTypes.rawValue] = settings.batchTypes
        blob[Key.searchAttribute.rawValue] = settings.searchAttribute.rawValue

        blob[Key.techViewsShootingMethodID.rawValue] = settings.techViewsShootingMethodID as Any? ?? NSNull()
        blob[Key.techViewsShootingMethodName.rawValue] = settings.techViewsShootingMethodName as Any? ?? NSNull()
        blob[Key.techViewsTemplateID.rawValue] = settings.techViewsTemplateID as Any? ?? NSNull()
        blob[Key.techViewsTemplateName.rawValue] = settings.techViewsTemplateName as Any? ?? NSNull()
        blob[Key.referenceAttributeConfigJSON.rawValue] =
            canonicalReferenceAttributeConfig(settings.referenceAttributeConfigJSON) as Any? ?? NSNull()

        blob[Key.techViewsCapturePersistence.rawValue] = settings.techViewsCapturePersistence.rawValue
        blob[Key.isOCREnabled.rawValue] = settings.isOCREnabled
        blob[Key.isMeasureEnabled.rawValue] = settings.isMeasureEnabled
        blob[Key.techViewsWhiteBalanceRaw.rawValue] = settings.techViewsWhiteBalanceRaw
        blob[Key.techViewsColorProfileRaw.rawValue] = settings.techViewsColorProfileRaw
        blob[Key.techViewsColorSpaceRaw.rawValue] = settings.techViewsColorSpaceRaw
        blob[Key.techViewsPresentationFocal.rawValue] = settings.techViewsPresentationFocal
        blob[Key.techViewsDetailFocal.rawValue] = settings.techViewsDetailFocal
        blob[Key.techViewsOCRFocal.rawValue] = settings.techViewsOCRFocal
        blob[Key.photoFilenamePresentationPattern.rawValue] = settings.photoFilenamePresentationPattern
        blob[Key.photoFilenameDetailPattern.rawValue] = settings.photoFilenameDetailPattern
        blob[Key.photoFilenameOCRPattern.rawValue] = settings.photoFilenameOCRPattern
        blob[Key.photoFilenameMeasurePattern.rawValue] = settings.photoFilenameMeasurePattern

        return blob
    }

    /// Apply a remotely-pulled blob to the active account's
    /// preferences. Unknown keys are ignored on read (the
    /// ping-pong-guard merge takes care of carrying them forward on
    /// the next push).
    public static func apply(_ blob: [String: Any], to settings: DevSettings) {
        let log = GSLogger(category: "SettingsSync")
        log.info("apply: blob keys = \(blob.keys.sorted().joined(separator: ", "))")
        if let raw = blob[Key.enabledStockItemStatuses.rawValue] {
            let bridged = (raw as? [Int]) ?? (raw as? [Any])?.compactMap { ($0 as? Int) ?? ($0 as? NSNumber)?.intValue }
            log.info("apply: enabledStockItemStatuses raw type=\(type(of: raw)) bridged=\(String(describing: bridged))")
        }
        if blob.keys.contains(Key.activeZone.rawValue) {
            settings.activeZone = blob[Key.activeZone.rawValue] as? String
        }
        // Defensive: accept either `[Int]` (the happy Foundation path
        // post-roundtrip) or `[Any]` with per-element coercion. The
        // previous bug was a silent skip when the cast fell through.
        if let raw = blob[Key.enabledStockItemStatuses.rawValue] {
            if let typed = raw as? [Int] {
                settings.enabledStockItemStatuses = Set(typed)
                log.info("apply: enabledStockItemStatuses ← \(typed.sorted())")
            } else if let any = raw as? [Any] {
                let ints = any.compactMap { ($0 as? Int) ?? ($0 as? NSNumber)?.intValue }
                settings.enabledStockItemStatuses = Set(ints)
                log.info("apply: enabledStockItemStatuses ←(coerced) \(ints.sorted())")
            } else {
                log.warning("apply: enabledStockItemStatuses unrecognised payload type \(type(of: raw))")
            }
        }
        if let v = blob[Key.defaultStockItemStatusOnRegister.rawValue] as? Int {
            settings.defaultStockItemStatusOnRegister = v
        }
        if let v = blob[Key.defaultStockItemStatusAfterTechViews.rawValue] as? Int {
            settings.defaultStockItemStatusAfterTechViews = v
        }
        if let raw = blob[Key.batchTypes.rawValue] {
            if let typed = raw as? [String] {
                settings.batchTypes = typed
            } else if let any = raw as? [Any] {
                settings.batchTypes = any.compactMap { $0 as? String }
            }
        }
        if let raw = blob[Key.searchAttribute.rawValue] as? String,
           let attr = StockService.SearchAttribute(rawValue: raw) {
            settings.searchAttribute = attr
        }
        if blob.keys.contains(Key.techViewsShootingMethodID.rawValue) {
            settings.techViewsShootingMethodID = blob[Key.techViewsShootingMethodID.rawValue] as? Int
        }
        if blob.keys.contains(Key.techViewsShootingMethodName.rawValue) {
            settings.techViewsShootingMethodName = blob[Key.techViewsShootingMethodName.rawValue] as? String
        }
        if blob.keys.contains(Key.techViewsTemplateID.rawValue) {
            settings.techViewsTemplateID = blob[Key.techViewsTemplateID.rawValue] as? Int
        }
        if blob.keys.contains(Key.techViewsTemplateName.rawValue) {
            settings.techViewsTemplateName = blob[Key.techViewsTemplateName.rawValue] as? String
        }
        if blob.keys.contains(Key.referenceAttributeConfigJSON.rawValue) {
            settings.referenceAttributeConfigJSON = blob[Key.referenceAttributeConfigJSON.rawValue] as? String
        }
        if let raw = blob[Key.techViewsCapturePersistence.rawValue] as? String,
           let mode = DevSettings.CapturePersistence(rawValue: raw) {
            settings.techViewsCapturePersistence = mode
        }
        if let v = blob[Key.isOCREnabled.rawValue] as? Bool {
            settings.isOCREnabled = v
        }
        if let v = blob[Key.isMeasureEnabled.rawValue] as? Bool {
            settings.isMeasureEnabled = v
        }
        if let v = blob[Key.techViewsWhiteBalanceRaw.rawValue] as? String {
            settings.techViewsWhiteBalanceRaw = v
        }
        if let v = blob[Key.techViewsColorProfileRaw.rawValue] as? String {
            settings.techViewsColorProfileRaw = v
        }
        if let v = blob[Key.techViewsColorSpaceRaw.rawValue] as? String {
            settings.techViewsColorSpaceRaw = v
        }
        if let v = blob[Key.techViewsPresentationFocal.rawValue] as? Int {
            settings.techViewsPresentationFocal = v
        }
        if let v = blob[Key.techViewsDetailFocal.rawValue] as? Int {
            settings.techViewsDetailFocal = v
        }
        if let v = blob[Key.techViewsOCRFocal.rawValue] as? Int {
            settings.techViewsOCRFocal = v
        }
        if let v = blob[Key.photoFilenamePresentationPattern.rawValue] as? String {
            settings.photoFilenamePresentationPattern = v
        }
        if let v = blob[Key.photoFilenameDetailPattern.rawValue] as? String {
            settings.photoFilenameDetailPattern = v
        }
        if let v = blob[Key.photoFilenameOCRPattern.rawValue] as? String {
            settings.photoFilenameOCRPattern = v
        }
        if let v = blob[Key.photoFilenameMeasurePattern.rawValue] as? String {
            settings.photoFilenameMeasurePattern = v
        }
    }

    /// Cross-platform wire format for `reference_attribute_config` is
    /// `"id=1;id=0;extra:key=1"` (what Android emits). iOS used to
    /// store the same data as a JSON array; convert on the fly so a
    /// push from an upgraded user lands in the canonical shape Android
    /// can read. Idempotent — non-legacy strings pass through.
    ///
    /// Kept inline (duplicates `ReferenceAttributeCatalog.decode/encode`
    /// over in GSApp) to avoid a reverse import; the migration is a
    /// one-shot kludge and can be deleted once every active install
    /// has re-saved its config in the new format.
    private static func canonicalReferenceAttributeConfig(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return raw }
        guard raw.hasPrefix("[") else { return raw }
        guard let data = raw.data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: data, options: []),
              let array = any as? [[String: Any]] else { return raw }
        let legacyIDRemap: [String: String] = [
            "productRef": "product_ref",
            "productSmalltext": "product_smalltext"
        ]
        let pairs = array.compactMap { dict -> String? in
            guard let id = dict["id"] as? String else { return nil }
            let visible = (dict["visible"] as? Bool) ?? false
            let mapped = legacyIDRemap[id] ?? id
            return "\(mapped)=\(visible ? 1 : 0)"
        }
        return pairs.joined(separator: ";")
    }

    /// True when the local snapshot equals the all-defaults blob (no
    /// custom workflow configured yet — push is grayed out).
    public static func isAllDefault(_ blob: [String: Any]) -> Bool {
        do {
            let a = try CanonicalHash.canonicalize(blob)
            let b = try CanonicalHash.canonicalize(defaultBlob())
            return a == b
        } catch {
            return false
        }
    }
}
