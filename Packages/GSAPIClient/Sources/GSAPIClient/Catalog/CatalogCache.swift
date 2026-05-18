import Foundation
import Observation
import GSCore

/// Single source of truth for the catalog data we keep client-side: zones,
/// shooting categories (with their view_types). Hydrated synchronously from
/// `UserDefaults` at init so the UI is never blank on cold launch, and
/// refreshed in the background after sign-in.
///
/// Observable, MainActor: SwiftUI views bind to it directly via `@Bindable`
/// (or read `.shared`) and re-render when zones / categories change.
@Observable
@MainActor
public final class CatalogCache {
    public static let shared = CatalogCache()

    public private(set) var zones: [Zone]
    public private(set) var categories: [Category]
    public private(set) var lastRefreshAt: Date?
    public private(set) var isRefreshing = false
    public private(set) var lastError: (any Error)?

    private init() {
        self.zones = CatalogPersistence.load([Zone].self, forKey: CatalogPersistence.Key.zones) ?? []
        self.categories = CatalogPersistence.load([Category].self, forKey: CatalogPersistence.Key.categories) ?? []
        if let ts = UserDefaults.standard.object(forKey: CatalogPersistence.Key.lastRefreshAt) as? Date {
            self.lastRefreshAt = ts
        }
    }

    /// Refresh zones + categories + batch types in parallel. Updates the
    /// observable state as each piece arrives so the UI can render
    /// progressively. Errors per slice don't bring down the others.
    public func refresh(environment: GSEnvironment) async {
        isRefreshing = true
        lastError = nil
        defer { isRefreshing = false }

        let zonesService = ZoneService(environment: environment)
        let categoriesService = CategoryService(environment: environment)
        let batchService = BatchService(environment: environment)

        async let zonesTask = withResult { try await zonesService.list() }
        async let categoriesTask = withResult { try await categoriesService.list() }
        async let batchTypesTask = withResult { try await batchService.sampleTypes() }

        let (zonesResult, categoriesResult, batchTypesResult) = await (zonesTask, categoriesTask, batchTypesTask)

        if case let .success(z) = zonesResult {
            zones = z
            CatalogPersistence.save(z, forKey: CatalogPersistence.Key.zones)
        } else if case let .failure(err) = zonesResult {
            lastError = err
        }
        if case let .success(c) = categoriesResult {
            categories = c
            CatalogPersistence.save(c, forKey: CatalogPersistence.Key.categories)
        } else if case let .failure(err) = categoriesResult {
            lastError = err
        }
        if case let .success(types) = batchTypesResult {
            // Seed the user-editable list with any *new* type the API
            // surfaces, but preserve user edits (ordering, manual entries).
            let existing = DevSettings.shared.batchTypes
            var merged = existing
            for type in types where !merged.contains(type) {
                merged.append(type)
            }
            if merged != existing {
                DevSettings.shared.batchTypes = merged
            }
        } else if case let .failure(err) = batchTypesResult {
            lastError = err
        }

        lastRefreshAt = Date()
        UserDefaults.standard.set(lastRefreshAt, forKey: CatalogPersistence.Key.lastRefreshAt)
    }

    /// True if the GS account has at least one zone configured. Drives
    /// "hide zone UI everywhere" behaviour when false.
    public var hasZones: Bool { !zones.isEmpty }

    /// Look up the user's currently-selected zone if any, falling back to
    /// the first available zone, or nil if the account has none.
    public func resolveActiveZone(settings: DevSettings) -> Zone? {
        if let id = settings.activeZoneID,
           let zone = zones.first(where: { $0.id == id }) {
            return zone
        }
        return zones.first
    }

    public func category(id: Int) -> Category? {
        categories.first(where: { $0.id == id })
    }
}

// MARK: - Helpers

private func withResult<T>(_ operation: @Sendable @escaping () async throws -> T) async -> Result<T, any Error> {
    do {
        return .success(try await operation())
    } catch {
        return .failure(error)
    }
}
