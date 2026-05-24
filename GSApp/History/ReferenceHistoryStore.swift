import Foundation
import Observation
import GSAPIClient

/// One row in the History tab — the user visited the reference
/// at `visitedAt` either via a barcode scan or via the manual
/// search. We snapshot just enough to render the row offline;
/// tapping it re-fetches the live `Reference` so the detail view
/// gets fresh stock + extras.
struct ReferenceHistoryEntry: Codable, Identifiable, Hashable {
    let ref: String
    let displayName: String
    let ean: String?
    /// Optional category breadcrumb (univers / gamme / family) so
    /// the row carries a bit of context without an extra fetch.
    let categoryBreadcrumb: String?
    let visitedAt: Date

    var id: String { ref }
}

/// App-wide store for the History tab. Records every visit to a
/// reference detail (whether reached via Scan or Search) and
/// persists the last 50 entries to UserDefaults. Re-visiting a
/// reference bumps it to the top — no duplicates.
@Observable
@MainActor
final class ReferenceHistoryStore {
    static let shared = ReferenceHistoryStore()

    private(set) var entries: [ReferenceHistoryEntry] = []

    private static let storageKey = "history.references.v1"
    private static let maxEntries = 50

    private init() {
        load()
    }

    /// Bumps `reference` to the top of the history. If an entry
    /// for the same `ref` already exists it's removed first so the
    /// list keeps only one row per reference (newest visit wins).
    func record(_ reference: Reference) {
        let entry = ReferenceHistoryEntry(
            ref: reference.ref,
            displayName: reference.displayName,
            ean: reference.ean,
            categoryBreadcrumb: makeBreadcrumb(reference),
            visitedAt: Date()
        )
        entries.removeAll { $0.ref == entry.ref }
        entries.insert(entry, at: 0)
        if entries.count > Self.maxEntries {
            entries = Array(entries.prefix(Self.maxEntries))
        }
        persist()
    }

    func remove(ref: String) {
        entries.removeAll { $0.ref == ref }
        persist()
    }

    func clear() {
        entries = []
        persist()
    }

    private func makeBreadcrumb(_ reference: Reference) -> String? {
        let parts = [reference.univers, reference.gamme, reference.family].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder.iso.decode([ReferenceHistoryEntry].self, from: data)
        else { return }
        entries = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder.iso.encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}

private extension JSONEncoder {
    /// Encoder that writes dates as ISO-8601 so the persisted
    /// history survives the kind of date-format drift that bites
    /// you when JSONEncoder's default switches representations.
    static let iso: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

private extension JSONDecoder {
    static let iso: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
