import SwiftUI
import GSAPIClient

/// History tab — last 50 reference detail pages the user visited
/// (via barcode scan or manual search). Tapping a row re-opens
/// the detail view, which in turn re-records the visit so the
/// entry bubbles back to the top.
struct HistoryTab: View {
    let settings: DevSettings
    @State private var store = ReferenceHistoryStore.shared
    @State private var showClearConfirm = false

    var body: some View {
        NavigationStack {
            Group {
                if store.entries.isEmpty {
                    ContentUnavailableView(
                        "No history yet",
                        systemImage: "clock",
                        description: Text("References you scan or open from search will appear here.")
                    )
                } else {
                    List {
                        ForEach(store.entries) { entry in
                            NavigationLink {
                                HistoryDetailLoader(settings: settings, entry: entry)
                            } label: {
                                HistoryRow(entry: entry)
                            }
                        }
                        .onDelete { indexSet in
                            for index in indexSet {
                                store.remove(ref: store.entries[index].ref)
                            }
                        }
                    }
                }
            }
            .navigationTitle("History")
            .toolbar {
                if !store.entries.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Clear", role: .destructive) {
                            showClearConfirm = true
                        }
                    }
                }
            }
            .confirmationDialog(
                "Clear history?",
                isPresented: $showClearConfirm,
                titleVisibility: .visible
            ) {
                Button("Clear", role: .destructive) { store.clear() }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
}

private struct HistoryRow: View {
    let entry: ReferenceHistoryEntry

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.secondary.opacity(0.12))
                    .frame(width: 44, height: 44)
                Image(systemName: "barcode.viewfinder")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.displayName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(entry.ref)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    if let ean = entry.ean {
                        Text("EAN \(ean)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                if let breadcrumb = entry.categoryBreadcrumb {
                    Text(breadcrumb)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Text(entry.visitedAt, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

/// Re-fetches the live `Reference` for a history entry and pushes
/// `ReferenceDetailView` once it lands. While the lookup is in
/// flight we show a centered progress indicator; on failure the
/// user gets a retry button. The detail screen's own .task then
/// re-records the visit (bumping it back to the top).
private struct HistoryDetailLoader: View {
    let settings: DevSettings
    let entry: ReferenceHistoryEntry

    enum LoadState {
        case loading
        case loaded(Reference)
        case failed(String)
    }

    @State private var state: LoadState = .loading

    var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .navigationTitle(entry.displayName)
                    .navigationBarTitleDisplayMode(.inline)
            case .loaded(let reference):
                ReferenceDetailView(
                    settings: settings,
                    source: .stock([ReferenceStock(reference: reference, stockItems: [])])
                )
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't load reference", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Retry") {
                        Task { await load() }
                    }
                }
            }
        }
        .task {
            if case .loading = state { await load() }
        }
    }

    @MainActor
    private func load() async {
        state = .loading
        let service = ReferenceLookupService(environment: settings.currentEnvironment)
        do {
            let results = try await service.lookup(scannedValue: entry.ref, by: .ref)
            if let match = results.first(where: { $0.ref == entry.ref }) ?? results.first {
                state = .loaded(match)
            } else {
                state = .failed("Reference not found.")
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
