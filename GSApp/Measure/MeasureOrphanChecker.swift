#if os(iOS)
import Foundation
import SwiftData
import GSAPIClient

/// Validates `MeasureCategory.gsCategoryID` links against the freshly
/// pulled Grand Shooting catalog and reports the orphans (links that
/// don't resolve to a known GS category anymore).
///
/// Used at app launch right after `CatalogCache.refresh` completes:
///   1. Fetch every `MeasureCategory` with a non-nil `gsCategoryID`.
///   2. Cross-check against `CatalogCache.categories`.
///   3. Surface a one-time alert with the first 5 affected names.
///   4. On the user's acknowledgement, null out the dangling ids.
enum MeasureOrphanChecker {

    @MainActor
    static func findOrphans(modelContext: ModelContext, catalog: CatalogCache) -> [MeasureCategory] {
        guard !catalog.categories.isEmpty else { return [] }
        let validIDs = Set(catalog.categories.map(\.id))
        let descriptor = FetchDescriptor<MeasureCategory>()
        guard let all = try? modelContext.fetch(descriptor) else { return [] }
        return all.filter { entry in
            guard let id = entry.gsCategoryID else { return false }
            return !validIDs.contains(id)
        }
    }

    @MainActor
    static func clearLinks(on orphans: [MeasureCategory], modelContext: ModelContext) {
        for entry in orphans {
            entry.gsCategoryID = nil
        }
        try? modelContext.save()
    }
}
#endif
