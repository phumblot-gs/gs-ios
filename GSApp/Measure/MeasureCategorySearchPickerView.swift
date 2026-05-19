#if os(iOS)
import SwiftUI
import SwiftData

/// Plain searchable list of local `MeasureCategory` rows, used by the
/// reference-bound measure flow when the reference's GS category has
/// no link to a local one yet. No visual ranking, no "create" CTA —
/// just pick from what's there.
struct MeasureCategorySearchPickerView: View {
    let onSelected: @MainActor (MeasureCategory) -> Void
    let onCancel: () -> Void

    @Query(sort: \MeasureCategory.createdAt, order: .reverse)
    private var categories: [MeasureCategory]

    @State private var search: String = ""

    private var filtered: [MeasureCategory] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return categories }
        return categories.filter { category in
            if category.name.lowercased().contains(needle) { return true }
            if let code = category.code, code.lowercased().contains(needle) { return true }
            return false
        }
    }

    var body: some View {
        Group {
            if categories.isEmpty {
                ContentUnavailableView {
                    Label("No measure category yet", systemImage: "ruler")
                } description: {
                    Text("Open the Measures tab and create a category that matches this product first.")
                }
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: search)
            } else {
                List {
                    ForEach(filtered) { category in
                        Button {
                            onSelected(category)
                        } label: {
                            row(category)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .searchable(
            text: $search,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search by name or code"
        )
        .navigationTitle("Choose a measure category")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") { onCancel() }
            }
        }
    }

    @ViewBuilder
    private func row(_ category: MeasureCategory) -> some View {
        HStack(spacing: 12) {
            thumbnail(for: category)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(category.name).font(.headline)
                HStack(spacing: 6) {
                    Text("\(category.templates.count) measurements")
                    if let code = category.code, !code.isEmpty {
                        Text("· \(code)").font(.caption.monospaced())
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func thumbnail(for category: MeasureCategory) -> some View {
        if let data = category.exampleImageData, let image = UIImage(data: data) {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            ZStack {
                Color.clear
                Image(systemName: "ruler").foregroundStyle(.secondary)
            }
            .background(.quaternary)
        }
    }
}
#endif
