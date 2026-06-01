import SwiftUI
import GSScanner
import GSAPIClient
import GSCore

/// Paginated list of batches with toolbar entries to scan a batch code
/// and to create a new batch.
struct BatchListView: View {
    let settings: DevSettings

    @State private var loader: PaginatedLoader<Batch>
    @State private var query: String = ""
    @State private var debouncedQuery: String = ""
    @State private var showScanner = false
    @State private var showCreate = false
    @State private var presentedBatch: Batch?
    @State private var scanError: String?

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
                if debouncedQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                    ContentUnavailableView(
                        "No batches yet",
                        systemImage: "shippingbox",
                        description: Text("Tap + to create your first batch, or scan one to open it.")
                    )
                } else {
                    ContentUnavailableView.search(text: debouncedQuery)
                }
            } else {
                ForEach(loader.items) { batch in
                    NavigationLink {
                        BatchDetailView(batch: batch, settings: settings)
                    } label: {
                        BatchRow(batch: batch, catalog: CatalogCache.shared)
                    }
                    .task { await loader.loadNextPageIfNeeded(at: batch) }
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
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search by name")
        .refreshable { await loader.refresh() }
        .task(id: debouncedQuery) {
            await refreshForCurrentQuery()
        }
        .onChange(of: query) { _, new in
            // Naive 300 ms debounce, mirroring the reference search.
            Task {
                try? await Task.sleep(for: .milliseconds(300))
                if query == new { debouncedQuery = new }
            }
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

    private func refreshForCurrentQuery() async {
        let trimmed = debouncedQuery.trimmingCharacters(in: .whitespaces)
        let service = BatchService(environment: settings.currentEnvironment)
        // Wildcard the value so GS does a substring match on the batch
        // name (`smalltext`) instead of expecting an exact value.
        let smalltext = trimmed.isEmpty ? nil : "*\(trimmed)*"
        let newLoader = PaginatedLoader<Batch> { offset in
            try await service.page(offset: offset, smalltext: smalltext)
        }
        loader = newLoader
        await newLoader.refresh()
    }
}

// MARK: - Row

private struct BatchRow: View {
    let batch: Batch
    let catalog: CatalogCache

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(batch.displayName)
                .font(.headline)
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
}
