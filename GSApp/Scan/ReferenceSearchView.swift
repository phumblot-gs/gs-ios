import SwiftUI
import GSAPIClient
import GSCore

/// Manual reference search — paginated list with a multi-attribute
/// `.searchable` field that matches on `ref`, `smalltext`, `sku` or `ean`
/// depending on user input (we just send the same value on every field
/// the server supports and merge dedupes downstream).
struct ReferenceSearchView: View {
    let settings: DevSettings

    @State private var query: String = ""
    @State private var debouncedQuery: String = ""
    @State private var loader: PaginatedLoader<Reference>

    init(settings: DevSettings) {
        self.settings = settings
        let service = ReferenceLookupService(environment: settings.currentEnvironment)
        _loader = State(initialValue: PaginatedLoader { offset in
            try await service.searchPage(query: [:], offset: offset)
        })
    }

    var body: some View {
        List {
            if loader.items.isEmpty && !loader.isLoading {
                ContentUnavailableView.search(text: debouncedQuery)
            } else {
                ForEach(loader.items) { ref in
                    NavigationLink {
                        ReferenceDetailView(
                            settings: settings,
                            source: .stock([ReferenceStock(reference: ref, stockItems: [])])
                        )
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(ref.displayName).font(.headline)
                            HStack(spacing: 8) {
                                Text(ref.ref)
                                    .font(.caption.monospaced())
                                if let ean = ref.ean {
                                    Text("EAN \(ean)")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .task { await loader.loadNextPageIfNeeded(at: ref) }
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
        .navigationTitle("Search references")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "ref, label, sku, ean…")
        .task(id: debouncedQuery) {
            await refreshForCurrentQuery()
        }
        .onChange(of: query) { _, new in
            // Naive 300 ms debounce.
            Task {
                try? await Task.sleep(for: .milliseconds(300))
                if query == new { debouncedQuery = new }
            }
        }
    }

    private func refreshForCurrentQuery() async {
        let trimmed = debouncedQuery.trimmingCharacters(in: .whitespaces)
        let service = ReferenceLookupService(environment: settings.currentEnvironment)
        let queryDict: [String: String] = trimmed.isEmpty ? [:] : [
            "smalltext": trimmed
        ]
        let newLoader = PaginatedLoader<Reference> { offset in
            try await service.searchPage(query: queryDict, offset: offset)
        }
        loader = newLoader
        await newLoader.refresh()
    }
}
