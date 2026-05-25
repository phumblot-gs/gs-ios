import SwiftUI
import GSScanner
import GSAPIClient
import GSCore

/// Shows a batch's metadata + its stock items. Each row is a
/// `ReferenceStock` (a reference with one or more stock items inside
/// this batch) — tapping it pushes `ReferenceDetailView`.
struct BatchDetailView: View {
    let initialBatch: Batch
    let settings: DevSettings

    @State private var currentBatch: Batch
    @State private var loader: PaginatedLoader<ReferenceStockRow>
    @State private var showEdit = false
    /// True after the first `onAppear` fires, so subsequent
    /// re-appearances (i.e. the user popped back from a pushed
    /// reference detail) can trigger a refresh — needed because
    /// moving a stock item to a different batch in the child
    /// view leaves this list stale otherwise.
    @State private var didFirstAppear = false

    // MARK: Filters
    /// Status ids the user wants to see. Initialised to the full
    /// set of enabled statuses → equivalent to "no filter" since
    /// only enabled statuses can be assigned to stock items anyway.
    @State private var selectedStatuses: Set<Int>
    @State private var refQuery: String = ""
    @State private var refDebounced: String = ""
    @State private var eanQuery: String = ""
    @State private var eanDebounced: String = ""
    @State private var showEANScanner = false

    init(batch: Batch, settings: DevSettings) {
        self.initialBatch = batch
        self.settings = settings
        _currentBatch = State(initialValue: batch)
        _selectedStatuses = State(initialValue: settings.enabledStockItemStatuses)
        let service = StockService(environment: settings.currentEnvironment)
        _loader = State(initialValue: PaginatedLoader { offset in
            let (items, page) = try await service.page(batchID: batch.id, offset: offset)
            return (items: items.map { ReferenceStockRow(rs: $0) }, pagination: page)
        })
    }

    var body: some View {
        List {
            metadataSection
            filtersSection
            contentsSection
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showEdit = true
                } label: {
                    Image(systemName: "pencil")
                }
                .accessibilityLabel("Edit batch")
            }
        }
        .task {
            if loader.items.isEmpty { await loader.refresh() }
        }
        .onAppear {
            if didFirstAppear {
                // Returning from a pushed detail (e.g. after a
                // batch move): refetch the contents so a removed
                // stock item disappears.
                Task { await rebuildLoader() }
            } else {
                didFirstAppear = true
            }
        }
        .refreshable { await rebuildLoader() }
        .sheet(isPresented: $showEdit) {
            BatchEditView(batch: currentBatch, settings: settings) { updated in
                currentBatch = updated
                showEdit = false
            }
        }
        .sheet(isPresented: $showEANScanner) {
            BatchContentsEANScanner { scanned in
                eanQuery = scanned
                showEANScanner = false
            }
        }
        // Debounce text inputs: copy to *Debounced after 300 ms of
        // no further typing. The loader observes the debounced
        // values so we don't fire a request on every keystroke.
        .onChange(of: refQuery) { _, new in
            Task {
                try? await Task.sleep(for: .milliseconds(300))
                if refQuery == new { refDebounced = new }
            }
        }
        .onChange(of: eanQuery) { _, new in
            Task {
                try? await Task.sleep(for: .milliseconds(300))
                if eanQuery == new { eanDebounced = new }
            }
        }
        .onChange(of: refDebounced) { Task { await rebuildLoader() } }
        .onChange(of: eanDebounced) { Task { await rebuildLoader() } }
        .onChange(of: selectedStatuses) { Task { await rebuildLoader() } }
    }

    /// Replaces the loader with a fresh one bound to the current
    /// filter values, then kicks off a refresh. Keeping the
    /// fetcher closure capture clean (filters are read at the
    /// call site) makes server-side filtering straightforward.
    @MainActor
    private func rebuildLoader() async {
        let service = StockService(environment: settings.currentEnvironment)
        let batchID = currentBatch.id
        let ref = refDebounced.trimmingCharacters(in: .whitespacesAndNewlines)
        let ean = eanDebounced.trimmingCharacters(in: .whitespacesAndNewlines)
        // Pass the status filter only when it's a proper subset of
        // the enabled statuses; otherwise omit so we don't blow
        // out the API with `in:` over the full set.
        let statusFilter: Set<Int>? = statusFilterPayload
        let newLoader = PaginatedLoader<ReferenceStockRow> { offset in
            let (items, page) = try await service.page(
                batchID: batchID,
                offset: offset,
                ref: ref.isEmpty ? nil : ref,
                ean: ean.isEmpty ? nil : ean,
                statuses: statusFilter
            )
            return (items: items.map { ReferenceStockRow(rs: $0) }, pagination: page)
        }
        loader = newLoader
        await newLoader.refresh()
    }

    /// Nil when the user has selected every enabled status (no
    /// filter applied). A non-empty set when they've narrowed
    /// down. An empty set after they unchecked everything — in
    /// that case we still send nothing and let the empty UI render
    /// because filtering by zero statuses returns nothing useful.
    private var statusFilterPayload: Set<Int>? {
        let enabled = settings.enabledStockItemStatuses
        let effective = selectedStatuses.intersection(enabled)
        if effective.isEmpty { return nil }            // user unchecked all → show all
        if effective == enabled { return nil }         // covering set = no filter
        return effective
    }

    @ViewBuilder
    private var metadataSection: some View {
        Section {
            LabeledContent("Name", value: currentBatch.smalltext ?? "—")
            LabeledContent("Code", value: currentBatch.code ?? "—")
                .font(.subheadline.monospaced())
            if let type = currentBatch.type, !type.isEmpty {
                LabeledContent("Type", value: type)
            }
            if let zone = currentBatch.zone, !zone.isEmpty {
                LabeledContent("Zone", value: zone)
            }
        } header: {
            Text("Batch info")
        }
    }

    @ViewBuilder
    private var filtersSection: some View {
        Section {
            // ref search — substring match, no scanner (scanner is
            // for EAN below).
            TextField("Ref", text: $refQuery)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            // EAN search — exact match. Scanner button fills the
            // text field with the scanned payload.
            HStack(spacing: 8) {
                TextField("EAN", text: $eanQuery)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.numbersAndPunctuation)
                Button {
                    showEANScanner = true
                } label: {
                    Image(systemName: "barcode.viewfinder")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Scan EAN")
            }
            statusFilterMenu
        } header: {
            Text("Filters")
        }
    }

    /// Status multi-select dropdown. Each enabled status appears
    /// as a Toggle inside a Menu; the menu label summarises the
    /// current selection ("All", "None", or "N selected").
    @ViewBuilder
    private var statusFilterMenu: some View {
        Menu {
            let enabled = settings.enabledStockItemStatuses
            ForEach(StockItemStatus.orderedCases, id: \.rawValue) { status in
                if enabled.contains(status.rawValue) {
                    Button {
                        if selectedStatuses.contains(status.rawValue) {
                            selectedStatuses.remove(status.rawValue)
                        } else {
                            selectedStatuses.insert(status.rawValue)
                        }
                    } label: {
                        HStack {
                            Text(status.displayName)
                            Spacer()
                            if selectedStatuses.contains(status.rawValue) {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        } label: {
            HStack {
                Label("Statuses", systemImage: "line.3.horizontal.decrease.circle")
                Spacer()
                Text(statusFilterSummary)
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            }
        }
    }

    /// Short string used as the menu's trailing label. "All" /
    /// "None" / "N selected" — keeps the row visually compact.
    private var statusFilterSummary: String {
        let enabled = settings.enabledStockItemStatuses
        let effective = selectedStatuses.intersection(enabled)
        if effective.isEmpty { return String(localized: "None") }
        if effective == enabled { return String(localized: "All") }
        return String(localized: "\(effective.count) selected")
    }

    private var contentsSection: some View {
        Section {
            if loader.items.isEmpty && !loader.isLoading {
                Text("This batch is empty.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(loader.items) { row in
                    NavigationLink {
                        ReferenceDetailView(settings: settings, source: .stock([row.rs]))
                    } label: {
                        StockRowView(rs: row.rs)
                    }
                    .task { await loader.loadNextPageIfNeeded(at: row) }
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
        } header: {
            HStack {
                Text("Contents")
                Spacer()
                if let total = loader.total {
                    Text("\(total)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Modal barcode reader used by `BatchDetailView` to fill the
/// EAN filter field. Same pattern as `BatchCreateView`'s scanner
/// — single-shot, dismisses on first hit, parent decides what to
/// do with the payload.
private struct BatchContentsEANScanner: View {
    let onScanned: @MainActor (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var lastScanned: String?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                LiveBarcodeScannerView(resetDelaySeconds: 0.6) { code in
                    guard lastScanned != code.payload else { return }
                    lastScanned = code.payload
                    onScanned(code.payload)
                }
                .ignoresSafeArea()

                Text("Aim at a barcode")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.6), in: Capsule())
                    .padding(.bottom, 40)
            }
            .navigationTitle("Scan EAN")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

struct ReferenceStockRow: Sendable, Hashable, Identifiable {
    let rs: ReferenceStock
    var id: String {
        rs.reference.ref + "#" + (rs.stockItems.map { String($0.id) }.joined(separator: ","))
    }
}

struct StockRowView: View {
    let rs: ReferenceStock

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(rs.reference.displayName)
                .font(.headline)
            Text(rs.reference.ref)
                .font(.subheadline.monospaced())
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(rs.stockItems, id: \.id) { item in
                    Text(item.status.displayName)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
            }
        }
        .padding(.vertical, 2)
    }
}
