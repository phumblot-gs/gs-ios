import Foundation
import GSAPIClient

/// One displayable attribute of a reference, identified by a stable
/// string `id`. Built-ins read a field off `Reference`; extra columns
/// (`id == "extra:<key>"`) read a custom catalog column — their value
/// extraction is wired in a later phase once the `/reference` payload
/// shape for those columns is confirmed (returns nil until then).
struct ReferenceAttribute: Identifiable, Hashable {
    let id: String
    /// Already-localized title (built-ins) or the raw account label
    /// (extra columns). Render with `Text(verbatim:)`.
    let label: String
    let value: (Reference) -> String?

    static func == (lhs: ReferenceAttribute, rhs: ReferenceAttribute) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Persisted, ordered visibility entry.
struct ReferenceAttributeConfigEntry: Codable, Hashable {
    let id: String
    var visible: Bool
}

enum ReferenceAttributeCatalog {
    /// Built-in attributes, in their default order. `ref` is excluded —
    /// it's always shown as the info block's header. Labels mirror the
    /// snake_case API field names from `/reference` — GS users
    /// recognise those (it's what they configure on their catalog),
    /// whereas localised "pretty" labels would obscure the link.
    static func builtIns() -> [ReferenceAttribute] {
        func nonEmpty(_ s: String?) -> String? {
            guard let s, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return s
        }
        return [
            ReferenceAttribute(id: "smalltext", label: "smalltext") { nonEmpty($0.smalltext) },
            ReferenceAttribute(id: "ean", label: "ean") { nonEmpty($0.ean) },
            ReferenceAttribute(id: "sku", label: "sku") { nonEmpty($0.sku) },
            ReferenceAttribute(id: "brand", label: "brand") { nonEmpty($0.brand) },
            ReferenceAttribute(id: "collection", label: "collection") { nonEmpty($0.collection) },
            ReferenceAttribute(id: "gender", label: "gender") { nonEmpty($0.gender) },
            ReferenceAttribute(id: "color", label: "color") { nonEmpty($0.color) },
            ReferenceAttribute(id: "size", label: "size") { nonEmpty($0.size) },
            ReferenceAttribute(id: "univers", label: "univers") { nonEmpty($0.univers) },
            ReferenceAttribute(id: "gamme", label: "gamme") { nonEmpty($0.gamme) },
            ReferenceAttribute(id: "family", label: "family") { nonEmpty($0.family) },
            ReferenceAttribute(id: "online", label: "online") { nonEmpty($0.online) },
            ReferenceAttribute(id: "product_ref", label: "product_ref") { nonEmpty($0.productRef) },
            ReferenceAttribute(id: "product_smalltext", label: "product_smalltext") { nonEmpty($0.productSmalltext) },
            ReferenceAttribute(id: "tags", label: "tags") {
                let joined = ($0.tags ?? []).joined(separator: ", ")
                return joined.isEmpty ? nil : joined
            },
            ReferenceAttribute(id: "eans", label: "eans") {
                let joined = ($0.eans ?? []).joined(separator: ", ")
                return joined.isEmpty ? nil : joined
            }
        ]
    }

    /// Attributes shown by default the first time (before the user
    /// customises anything). Extra columns default to hidden.
    static let defaultVisibleIDs: Set<String> = [
        "smalltext", "ean", "brand", "color", "size", "univers", "gamme", "family"
    ]

    /// Extra columns of the active account as attributes. Their values
    /// live under `reference.extra.<key>`.
    static func extraColumnAttributes(_ columns: [CatalogExtraColumn]) -> [ReferenceAttribute] {
        columns.compactMap { col in
            guard col.isDisplayable, let key = col.key, let label = col.label else { return nil }
            return ReferenceAttribute(id: "extra:\(key)", label: label) { reference in
                reference.extra?.displayValue(forKey: key)
            }
        }
    }

    /// Every available attribute for the active account: built-ins then
    /// extra columns.
    static func available(extraColumns: [CatalogExtraColumn]) -> [ReferenceAttribute] {
        builtIns() + extraColumnAttributes(extraColumns)
    }

    // MARK: - Config (de)serialisation + reconciliation

    /// Map of obsolete iOS-local attribute ids (camelCase) → their
    /// current snake_case equivalent shared with Android. Applied at
    /// decode so an existing user keeps their saved order when the
    /// iOS schema realigns with the cross-platform wire format.
    private static let legacyIDRemap: [String: String] = [
        "productRef": "product_ref",
        "productSmalltext": "product_smalltext"
    ]

    /// Decodes the persisted config. Two formats are accepted:
    ///
    ///  - **Canonical** (cross-platform, what Android uses + iOS now
    ///    emits): `"key=1;key=0;extra:foo=1"` — semicolon-separated
    ///    `id=0|1` pairs.
    ///  - **Legacy iOS** (pre-sync builds): JSON array of
    ///    `{"id": "...", "visible": true|false}` objects. Detected by
    ///    a leading `[`. Existing users keep their config; the next
    ///    `encode` re-saves in canonical form.
    ///
    /// Unknown ids are kept verbatim — `reconciled(...)` drops them
    /// against the active account's `available` list. Obsolete iOS
    /// ids are remapped here so old persisted entries don't get
    /// orphaned.
    static func decode(_ raw: String?) -> [ReferenceAttributeConfigEntry] {
        guard let raw, !raw.isEmpty else { return [] }
        let entries: [ReferenceAttributeConfigEntry]
        if raw.hasPrefix("[") {
            entries = decodeLegacyJSON(raw)
        } else {
            entries = decodeCanonical(raw)
        }
        return entries.map { entry in
            if let renamed = legacyIDRemap[entry.id] {
                return ReferenceAttributeConfigEntry(id: renamed, visible: entry.visible)
            }
            return entry
        }
    }

    private static func decodeCanonical(_ raw: String) -> [ReferenceAttributeConfigEntry] {
        raw.split(separator: ";").compactMap { token in
            // `extra:<key>` ids contain a colon (no `=`), so the last
            // `=` is the visibility separator — never the first.
            guard let eqIndex = token.lastIndex(of: "="), eqIndex != token.startIndex else {
                return nil
            }
            let id = String(token[..<eqIndex])
            let flag = String(token[token.index(after: eqIndex)...])
            return ReferenceAttributeConfigEntry(id: id, visible: flag == "1")
        }
    }

    private static func decodeLegacyJSON(_ raw: String) -> [ReferenceAttributeConfigEntry] {
        guard let data = raw.data(using: .utf8),
              let entries = try? JSONDecoder().decode([ReferenceAttributeConfigEntry].self, from: data)
        else { return [] }
        return entries
    }

    /// Emits the canonical cross-platform string. Used both on every
    /// local edit (so what we save matches what we'd push) and
    /// indirectly by `SyncableSettings.snapshot` via the persisted
    /// `referenceAttributeConfigJSON`.
    static func encode(_ entries: [ReferenceAttributeConfigEntry]) -> String? {
        guard !entries.isEmpty else { return "" }
        return entries
            .map { "\($0.id)=\($0.visible ? 1 : 0)" }
            .joined(separator: ";")
    }

    /// Merges the stored config with the currently-available attributes:
    /// stored order wins, attributes no longer available are dropped,
    /// and newly-available ones are appended with their default
    /// visibility. Returns attribute + visibility pairs in display order.
    static func reconciled(
        available: [ReferenceAttribute],
        storedJSON: String?
    ) -> [(attribute: ReferenceAttribute, visible: Bool)] {
        let byID = Dictionary(uniqueKeysWithValues: available.map { ($0.id, $0) })
        let stored = decode(storedJSON)
        var result: [(ReferenceAttribute, Bool)] = []
        var seen = Set<String>()
        for entry in stored {
            guard let attribute = byID[entry.id], !seen.contains(entry.id) else { continue }
            result.append((attribute, entry.visible))
            seen.insert(entry.id)
        }
        for attribute in available where !seen.contains(attribute.id) {
            result.append((attribute, defaultVisibleIDs.contains(attribute.id)))
        }
        return result.map { (attribute: $0.0, visible: $0.1) }
    }
}
