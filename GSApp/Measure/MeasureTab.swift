import SwiftUI
import SwiftData
import GSAPIClient
import GSCore

/// Root of the "Mesures" tab. LiDAR-only feature gated through
/// `GSDeviceSupport.hasLiDAR` — non-LiDAR devices see a friendly
/// explanation instead of broken UI.
struct MeasureTab: View {
    let settings: DevSettings

    var body: some View {
        NavigationStack {
            Group {
                #if os(iOS)
                if GSDeviceSupport.hasLiDAR {
                    MeasureCategoryListView(settings: settings)
                } else {
                    notSupportedView
                }
                #else
                notSupportedView
                #endif
            }
            .navigationTitle("Measures")
        }
    }

    private var notSupportedView: some View {
        ContentUnavailableView {
            Label("Measures need LiDAR", systemImage: "cube.transparent.fill")
        } description: {
            Text("Measure works only on devices with a LiDAR scanner — iPhone Pro / Pro Max and iPad Pro.")
        }
    }
}

#if os(iOS)
/// Categories list — entry point for opening an existing category for
/// edit or starting a new measure flow.
struct MeasureCategoryListView: View {
    let settings: DevSettings

    @Query(sort: \MeasureCategory.createdAt, order: .reverse) private var categories: [MeasureCategory]
    @State private var showFlow = false
    @State private var searchText = ""

    private var filteredCategories: [MeasureCategory] {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return categories }
        let needle = trimmed.lowercased()
        return categories.filter { category in
            if category.name.lowercased().contains(needle) { return true }
            if let code = category.code, code.lowercased().contains(needle) { return true }
            return false
        }
    }

    @ViewBuilder
    private func categoryRow(_ category: MeasureCategory) -> some View {
        HStack(spacing: 12) {
            thumbnail(for: category)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(category.name).font(.headline)
                HStack(spacing: 6) {
                    Text("\(category.templates.count) measurements")
                    if let code = category.code, !code.isEmpty {
                        Text("· \(code)")
                            .font(.caption.monospaced())
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func thumbnail(for category: MeasureCategory) -> some View {
        if let data = category.exampleImageData, let image = UIImage(data: data) {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            ZStack {
                Color.clear
                Image(systemName: "ruler")
                    .foregroundStyle(.secondary)
            }
            .background(.quaternary)
        }
    }

    var body: some View {
        Group {
            if categories.isEmpty {
                ContentUnavailableView {
                    Label("No categories yet", systemImage: "ruler")
                } description: {
                    Text("Start a measurement to capture an object. The first capture creates a category; subsequent ones are recognised automatically.")
                }
            } else {
                List {
                    if filteredCategories.isEmpty {
                        ContentUnavailableView.search(text: searchText)
                    } else {
                        ForEach(filteredCategories) { category in
                            NavigationLink {
                                MeasureCategoryEditView(category: category)
                            } label: {
                                categoryRow(category)
                            }
                        }
                    }
                }
                .searchable(
                    text: $searchText,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search by name or code"
                )
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showFlow = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .fullScreenCover(isPresented: $showFlow) {
            MeasureFlowView(settings: settings) {
                showFlow = false
            }
        }
    }
}
#endif
