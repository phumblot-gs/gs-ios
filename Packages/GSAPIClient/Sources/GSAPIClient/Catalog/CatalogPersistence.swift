import Foundation

/// Tiny UserDefaults JSON wrapper used by `CatalogCache` to survive app
/// restarts without a heavyweight persistent store. Anything small enough
/// to JSON-encode in a few KB belongs here (zones, categories, batch
/// types). For larger blobs we'd move to a file in `~/Documents` or
/// SwiftData, but the catalog data is tiny.
enum CatalogPersistence {

    static func load<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, forKey key: String) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func delete(forKey key: String) {
        UserDefaults.standard.removeObject(forKey: key)
    }

    enum Key {
        static let zones = "catalog.zones"
        static let categories = "catalog.categories"
        static let lastRefreshAt = "catalog.lastRefreshAt"
    }
}
