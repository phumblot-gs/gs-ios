import SwiftUI
import GSAPIClient
import GSCore

/// Modal picker for the "Change batch" action on the reference
/// detail. Shows the paginated batch list with a search field,
/// a scan button for barcode lookup, and a `+` toolbar entry
/// to create a new batch on the fly. Tapping a row immediately
/// hands the chosen batch back to the parent.
struct BatchPickerSheet: View {
    let settings: DevSettings
    /// Optional id of the batch the stock item is currently in,
    /// used purely to mark that row with a checkmark.
    let currentBatchID: Int?
    let onSelect: @MainActor (Batch) -> Void

    @State private var loader: PaginatedLoader<Batch>
    @State private var query: String = ""
    @State private var showScanner = false
    @State private var showCreate = false
    @State private var scanError: String?

    init(
        settings: DevSettings,
        currentBatchID: Int?,
        onSelect: @escaping @MainActor (Batch) -> Void
    ) {
        self.settings = settings
        self.currentBatchID = currentBatchID
        self.onSelect = onSelect
        let service = BatchService(environment: settings.currentEnvironment)
        _loader = State(initialValue: PaginatedLoader { offset in
            try await service.page(offset: offset)
        })
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(filteredBatches) { batch in
                    Button {
                        onSelect(batch)
                    } label: {
                        BatchPickerRow(
                            batch: batch,
                            isCurrent: batch.id == currentBatchID
                        )
                    }
                    .foregroundStyle(.primary)
                    .task { await loader.loadNextPageIfNeeded(at: batch) }
                }
                if loader.isLoading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
                if filteredBatches.isEmpty && !loader.isLoading && loader.error == nil {
                    ContentUnavailableView.search(text: query)
                }
                if let err = loader.error {
                    Label(err.localizedDescription, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search by name, code or type"
            )
            .navigationTitle("Pick a batch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
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
                        onSelect(batch)
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
                    onSelect(newBatch)
                }
            }
            .alert(
                "Scan failed",
                isPresented: Binding(
                    get: { scanError != nil },
                    set: { if !$0 { scanError = nil } }
                )
            ) {
                Button("OK") { scanError = nil }
            } message: {
                Text(scanError ?? "")
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// The current trimmed query, lower-cased once for the
    /// case-insensitive compare loop below.
    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Filtered view of the loaded batches. Three behaviours:
    /// - Empty query → return the full list as-is.
    /// - Query that looks like a barcode (alphanumeric, length ≥4)
    ///   → also keep batches whose `code` matches exactly. The
    ///   API-side exact-code lookup is exposed via the scan
    ///   button — here we keep client-side filtering so search
    ///   feels responsive without extra network roundtrips on
    ///   every keystroke.
    /// - Free-text query → substring match on `smalltext`, `code`,
    ///   `type`, all case-insensitive.
    private var filteredBatches: [Batch] {
        guard !trimmedQuery.isEmpty else { return loader.items }
        return loader.items.filter { batch in
            let smalltext = (batch.smalltext ?? "").lowercased()
            let code = (batch.code ?? "").lowercased()
            let type = (batch.type ?? "").lowercased()
            return smalltext.contains(trimmedQuery)
                || code.contains(trimmedQuery)
                || type.contains(trimmedQuery)
        }
    }
}

private struct BatchPickerRow: View {
    let batch: Batch
    let isCurrent: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(batch.displayName)
                    .font(.subheadline.weight(.medium))
                HStack(spacing: 6) {
                    if let type = batch.type, !type.isEmpty {
                        Text(type)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                    if let zone = batch.zone, !zone.isEmpty {
                        Label(zone, systemImage: "mappin.circle")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let code = batch.code, !code.isEmpty {
                        Text(code)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer()
            if isCurrent {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
            }
        }
    }
}
