import SwiftUI
import GSScanner
import GSAPIClient
import GSCore

/// Paginated list of batches with toolbar entries to scan a batch code
/// and to create a new batch.
struct BatchListView: View {
    let settings: DevSettings

    @State private var loader: PaginatedLoader<Batch>
    @State private var showScanner = false
    @State private var showCreate = false
    @State private var presentedBatch: Batch?
    @State private var scanError: String?
    /// Per-batch stock-item count, lazily fetched the first time
    /// the row appears. Lives for the lifetime of the screen; on
    /// pull-to-refresh we wipe and refetch.
    @State private var counts: [Int: BatchCountState] = [:]

    /// State of a single batch's count fetch.
    enum BatchCountState: Equatable {
        case loading
        case loaded(count: Int, partial: Bool)
        case failed
    }

    init(settings: DevSettings) {
        self.settings = settings
        let service = BatchService(environment: settings.currentEnvironment)
        _loader = State(initialValue: PaginatedLoader { offset in
            try await service.page(offset: offset)
        })
    }

    var body: some View {
        List {
            if loader.items.isEmpty && !loader.isLoading {
                ContentUnavailableView(
                    "No batches yet",
                    systemImage: "shippingbox",
                    description: Text("Tap + to create your first batch, or scan one to open it.")
                )
            } else {
                ForEach(loader.items) { batch in
                    NavigationLink {
                        BatchDetailView(batch: batch, settings: settings)
                    } label: {
                        BatchRow(
                            batch: batch,
                            catalog: CatalogCache.shared,
                            countState: counts[batch.id]
                        )
                    }
                    .task {
                        await loader.loadNextPageIfNeeded(at: batch)
                        await loadCountIfNeeded(for: batch)
                    }
                }
                if loader.isLoading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
                if let err = loader.error {
                    Label(err.localizedDescription, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }
        }
        .navigationTitle("Batches")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showScanner = true
                } label: {
                    Image(systemName: "barcode.viewfinder")
                }
                .accessibilityLabel("Scan batch")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showCreate = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Create batch")
            }
        }
        .refreshable {
            counts.removeAll()
            await loader.refresh()
        }
        .task {
            if loader.items.isEmpty { await loader.refresh() }
        }
        .sheet(isPresented: $showScanner) {
            BatchScanView(
                settings: settings,
                onFound: { batch in
                    showScanner = false
                    presentedBatch = batch
                },
                onFailed: { message in
                    showScanner = false
                    scanError = message
                }
            )
        }
        .sheet(isPresented: $showCreate) {
            BatchCreateView(settings: settings) { newBatch in
                showCreate = false
                Task { await loader.refresh() }
                presentedBatch = newBatch
            }
        }
        .navigationDestination(item: $presentedBatch) { batch in
            BatchDetailView(batch: batch, settings: settings)
        }
        .alert("Scan failed", isPresented: Binding(
            get: { scanError != nil },
            set: { if !$0 { scanError = nil } }
        )) {
            Button("OK") { scanError = nil }
        } message: {
            Text(scanError ?? "")
        }
    }

    /// Fetches the stock-item count for `batch` the first time
    /// its row scrolls into view. Idempotent — re-entering the row
    /// won't kick off a second request.
    @MainActor
    private func loadCountIfNeeded(for batch: Batch) async {
        guard counts[batch.id] == nil else { return }
        counts[batch.id] = .loading
        let service = StockService(environment: settings.currentEnvironment)
        do {
            let (refs, pagination) = try await service.page(batchID: batch.id, offset: 0)
            let count = refs.reduce(0) { $0 + $1.stockItems.count }
            counts[batch.id] = .loaded(count: count, partial: pagination.hasMore)
        } catch {
            counts[batch.id] = .failed
        }
    }
}

// MARK: - Row

private struct BatchRow: View {
    let batch: Batch
    let catalog: CatalogCache
    let countState: BatchListView.BatchCountState?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(batch.displayName)
                    .font(.headline)
                Spacer()
                countBadge
            }
            HStack(spacing: 8) {
                if let type = batch.type, !type.isEmpty {
                    Text(type)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                if let zone = batch.zone, !zone.isEmpty {
                    Label(zone, systemImage: "mappin.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let code = batch.code, !code.isEmpty {
                    Label(code, systemImage: "barcode")
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// Small badge on the trailing edge showing the loaded stock-
    /// item count. Loading state shows a spinner, failure stays
    /// silent (we don't want a red icon every time a batch fetch
    /// hiccups). `partial == true` appends a `+` since only the
    /// first 100 references were summed.
    @ViewBuilder
    private var countBadge: some View {
        switch countState {
        case .loading:
            ProgressView().controlSize(.mini)
        case .loaded(let count, let partial):
            Label(
                "\(count)\(partial ? "+" : "") items",
                systemImage: "shippingbox"
            )
            .font(.caption.weight(.medium))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(.secondary)
        case .failed, .none:
            EmptyView()
        }
    }
}
