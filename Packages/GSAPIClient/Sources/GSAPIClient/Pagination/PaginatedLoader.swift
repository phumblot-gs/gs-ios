import Foundation
import Observation

/// Generic page-by-page loader for any list endpoint. Holds the running
/// `items` array, the loaded `total`, and the inflight state — SwiftUI
/// views observe it via `@Bindable` and trigger `loadNextPageIfNeeded(at:)`
/// when the bottom row appears.
@Observable
@MainActor
public final class PaginatedLoader<Item: Sendable & Hashable & Identifiable>
where Item.ID: Hashable {

    public typealias Fetcher = @Sendable (_ offset: Int) async throws -> (items: [Item], pagination: PaginationInfo)

    public private(set) var items: [Item] = []
    public private(set) var total: Int?
    public private(set) var isLoading = false
    public private(set) var hasMore = true
    public private(set) var error: (any Error)?

    private let fetcher: Fetcher
    private var nextOffset = 0
    private var seenIDs: Set<Item.ID> = []

    public init(fetcher: @escaping Fetcher) {
        self.fetcher = fetcher
    }

    /// Wipes the current state and reloads the first page from offset 0.
    public func refresh() async {
        items.removeAll()
        seenIDs.removeAll()
        nextOffset = 0
        total = nil
        hasMore = true
        error = nil
        await loadNextPage()
    }

    /// Idempotently triggers the next page load. Called from views, e.g.
    /// `.onAppear` on the last visible row.
    public func loadNextPageIfNeeded(at item: Item) async {
        guard hasMore, !isLoading else { return }
        // Only fire when the appearing row is near the tail of the current list.
        guard let index = items.firstIndex(of: item), index >= items.count - 5 else {
            return
        }
        await loadNextPage()
    }

    /// Direct trigger, useful for explicit "Load more" buttons.
    public func loadNextPage() async {
        guard hasMore, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await fetcher(nextOffset)
            for item in result.items where !seenIDs.contains(item.id) {
                items.append(item)
                seenIDs.insert(item.id)
            }
            total = result.pagination.total ?? total
            nextOffset = result.pagination.nextOffset
            hasMore = result.pagination.hasMore
            error = nil
        } catch {
            self.error = error
        }
    }
}
