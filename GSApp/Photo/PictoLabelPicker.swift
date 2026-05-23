import SwiftUI
import SwiftData
import UIKit

/// Sheet shown when the user taps a pictogram in the annotation
/// view to assign or change its label. Lists every previously
/// learned picto, sorted by `matchCount` (most used first) then by
/// creation date for stable order on ties. A search field narrows
/// the list, and an inline "+ New label" form lets the user teach
/// a brand-new picto when nothing in the library fits.
struct PictoLabelPicker: View {
    @Binding var annotation: PictoAnnotation
    let onDismiss: () -> Void

    @Query(sort: [
        SortDescriptor(\LearnedPictogram.matchCount, order: .reverse),
        SortDescriptor(\LearnedPictogram.createdAt, order: .reverse)
    ]) private var library: [LearnedPictogram]

    @State private var searchText: String = ""
    @State private var showAddForm: Bool = false
    @State private var newLabel: String = ""
    @State private var newCategory: TechViewCategory = .composition

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if showAddForm {
                    addForm
                    Divider()
                }
                listSection
            }
            .navigationTitle("Pictogram label")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        withAnimation { showAddForm.toggle() }
                    } label: {
                        Label(showAddForm ? "Hide" : "New", systemImage: showAddForm ? "minus.circle" : "plus.circle")
                            .labelStyle(.titleAndIcon)
                    }
                }
            }
        }
    }

    // MARK: - List

    private var listSection: some View {
        List {
            if filtered.isEmpty {
                emptyRow
            } else {
                ForEach(filtered, id: \.persistentModelID) { entry in
                    Button { select(entry) } label: { entryRow(entry) }
                        .buttonStyle(.plain)
                }
            }
        }
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search labels")
        .listStyle(.plain)
    }

    private var emptyRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(searchText.isEmpty ? "No labels yet" : "No matches")
                .font(.subheadline.weight(.medium))
            Text(searchText.isEmpty
                 ? "Tap “New” to teach the first picto."
                 : "Tap “New” to add this as a new label.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

    private func entryRow(_ entry: LearnedPictogram) -> some View {
        HStack(spacing: 12) {
            thumbnail(for: entry)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.label)
                    .font(.body)
                    .foregroundStyle(.primary)
                if let category = entry.category {
                    Label(category.displayName, systemImage: category.symbolName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if entry.matchCount > 0 {
                Text("\(entry.matchCount)×")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.18), in: Capsule())
            }
            if isCurrentlyAssigned(entry) {
                Image(systemName: "checkmark")
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func thumbnail(for entry: LearnedPictogram) -> some View {
        if let image = UIImage(data: entry.thumbnailData) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: 40, height: 40)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.gray.opacity(0.2))
                .frame(width: 40, height: 40)
                .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
        }
    }

    private var filtered: [LearnedPictogram] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return library }
        return library.filter { $0.label.lowercased().contains(needle) }
    }

    private func isCurrentlyAssigned(_ entry: LearnedPictogram) -> Bool {
        annotation.matchedLearnedID == entry.persistentModelID
    }

    private func select(_ entry: LearnedPictogram) {
        var copy = annotation
        copy.label = entry.label
        copy.category = entry.category
        copy.matchedLearnedID = entry.persistentModelID
        copy.suggestionDistance = nil
        annotation = copy
        onDismiss()
    }

    // MARK: - Add new form

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New pictogram label")
                .font(.subheadline.weight(.semibold))
            TextField("Label (e.g. Wash 30°)", text: $newLabel)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.sentences)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit(commitNew)
            HStack {
                Text("Category")
                    .font(.subheadline)
                Spacer()
                Picker("Category", selection: $newCategory) {
                    ForEach(TechViewCategory.allCases) { cat in
                        Label(cat.displayName, systemImage: cat.symbolName).tag(cat)
                    }
                }
                .pickerStyle(.menu)
            }
            HStack {
                Spacer()
                Button("Add label") { commitNew() }
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmedNewLabel.isEmpty)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(.thinMaterial)
    }

    private var trimmedNewLabel: String {
        newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commitNew() {
        let label = trimmedNewLabel
        guard !label.isEmpty else { return }
        var copy = annotation
        copy.label = label
        copy.category = newCategory
        // No existing learned id — the capture-view save flow will
        // create a fresh LearnedPictogram for this candidate.
        copy.matchedLearnedID = nil
        copy.suggestionDistance = nil
        annotation = copy
        onDismiss()
    }
}
