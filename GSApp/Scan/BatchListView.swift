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
        .refreshable { await loader.refresh() }
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
                if let zoneID = batch.zoneID,
                   let zone = catalog.zones.first(where: { $0.id == zoneID }),
                   let label = zone.smalltext {
                    Label(label, systemImage: "mappin.circle")
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
