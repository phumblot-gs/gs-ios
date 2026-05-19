#if os(iOS)
import SwiftUI
import GSAPIClient

/// Sheet-based picker for selecting the Grand Shooting catalog category
/// a `MeasureCategory` should link to. Triggers via a "Link to…" row in
/// the Create / Edit forms; on confirmation we just write the chosen
/// `category_id` back into the binding.
struct GSCategoryPickerSheet: View {
    @Binding var selection: Int?
    @Environment(\.dismiss) private var dismiss
    @State private var search: String = ""

    private let catalog = CatalogCache.shared

    private var sortedCategories: [GSAPIClient.Category] {
        catalog.categories.sorted { lhs, rhs in
            // Primary sort: ranking ascending. Categories without a
            // ranking fall to the end.
            let lr = lhs.ranking ?? Int.max
            let rr = rhs.ranking ?? Int.max
            if lr != rr { return lr < rr }
            // Tie-break on smalltext to keep the order stable.
            return (lhs.smalltext ?? "") < (rhs.smalltext ?? "")
        }
    }

    private var filteredCategories: [GSAPIClient.Category] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return sortedCategories }
        return sortedCategories.filter { ($0.smalltext ?? "").lowercased().contains(needle) }
    }

    var body: some View {
        NavigationStack {
            List {
                if selection != nil {
                    Section {
                        Button("Clear association", role: .destructive) {
                            selection = nil
                            dismiss()
                        }
                    }
                }
                if catalog.categories.isEmpty {
                    Section {
                        ContentUnavailableView {
                            Label("Catalog not loaded", systemImage: "tray.and.arrow.down")
                        } description: {
                            Text("The Grand Shooting catalog hasn't been pulled yet. Open Settings → Workflow → Refresh catalog.")
                        }
                    }
                } else if filteredCategories.isEmpty {
                    Section {
                        ContentUnavailableView.search(text: search)
                    }
                } else {
                    Section {
                        ForEach(filteredCategories) { gsCategory in
                            Button {
                                selection = gsCategory.id
                                dismiss()
                            } label: {
                                row(gsCategory)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .searchable(
                text: $search,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Filter by name"
            )
            .navigationTitle("Grand Shooting category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ category: GSAPIClient.Category) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(category.smalltext ?? "Category #\(category.id)")
                    .foregroundStyle(.primary)
                Text("\(category.viewTypes.count) view(s) expected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if selection == category.id {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
            }
        }
    }
}

/// Row used inside Forms to surface the current GS link and trigger the
/// picker sheet. Renders three states: no link, link to a known
/// category (smalltext + rank + view count), or link to a stale id
/// (Category #N not in catalog).
struct GSCategoryLinkRow: View {
    @Binding var selection: Int?
    @State private var showSheet = false

    private let catalog = CatalogCache.shared

    var body: some View {
        Button {
            showSheet = true
        } label: {
            HStack {
                content
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showSheet) {
            GSCategoryPickerSheet(selection: $selection)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let id = selection {
            if let category = catalog.category(id: id) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(category.smalltext ?? "Category #\(category.id)")
                        .foregroundStyle(.primary)
                    HStack(spacing: 8) {
                        if let rank = category.ranking {
                            Text("Rank \(rank)")
                                .font(.caption.monospacedDigit())
                        }
                        Text("\(category.viewTypes.count) view(s) expected")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
            } else {
                // Stale link — the linked id isn't in the local catalog.
                // The orphan check at next refresh will clear this; in
                // the meantime we surface what we know so the user
                // realises something's off.
                VStack(alignment: .leading, spacing: 2) {
                    Text("Category #\(id)")
                        .foregroundStyle(.primary)
                    Text("Not in catalog — will be cleared on next refresh")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        } else {
            Label("Link to a Grand Shooting category", systemImage: "link")
                .foregroundStyle(.primary)
        }
    }
}
#endif
