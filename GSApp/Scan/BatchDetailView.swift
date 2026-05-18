import SwiftUI
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

    init(batch: Batch, settings: DevSettings) {
        self.initialBatch = batch
        self.settings = settings
        _currentBatch = State(initialValue: batch)
        let service = StockService(environment: settings.currentEnvironment)
        _loader = State(initialValue: PaginatedLoader { offset in
            let (items, page) = try await service.page(batchID: batch.id, offset: offset)
            return (items: items.map { ReferenceStockRow(rs: $0) }, pagination: page)
        })
    }

    var body: some View {
        List {
            metadataSection
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
        .refreshable { await loader.refresh() }
        .sheet(isPresented: $showEdit) {
            BatchEditView(batch: currentBatch, settings: settings) { updated in
                currentBatch = updated
                showEdit = false
            }
        }
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
