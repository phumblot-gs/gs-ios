#if os(iOS)
import SwiftUI
import SwiftData
import GSAPIClient

/// In-place editor for an existing `MeasureCategory`: rename, change
/// the optional code, add / remove / rename the measurements, or
/// delete the whole category.
///
/// Direct binding via `@Bindable` — SwiftData persists mutations as
/// they happen; we just call `modelContext.save()` on exit for safety.
struct MeasureCategoryEditView: View {
    @Bindable var category: MeasureCategory

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var newMeasurementName: String = ""
    @State private var showDeleteConfirm = false

    private var sortedTemplates: [MeasurementTemplate] {
        category.templates.sorted { $0.order < $1.order }
    }

    var body: some View {
        Form {
            previewSection
            identitySection
            gsCategorySection
            measurementsSection
            dangerSection
        }
        .navigationTitle(category.name)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            try? modelContext.save()
        }
        .confirmationDialog(
            "Delete this category?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                modelContext.delete(category)
                try? modelContext.save()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All measurements defined under this category will also be removed. This cannot be undone.")
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var previewSection: some View {
        if let data = category.exampleImageData, let image = UIImage(data: data) {
            Section {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 160)
                    .cornerRadius(10)
            } footer: {
                Text("Visual reference used to suggest this category on future captures.")
            }
        }
    }

    private var identitySection: some View {
        Section {
            TextField("Category name", text: $category.name)
                .autocorrectionDisabled()
            TextField(
                "Code (optional, e.g. ERP / catalog code)",
                text: Binding(
                    get: { category.code ?? "" },
                    set: { category.code = $0.isEmpty ? nil : $0 }
                )
            )
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
        } header: {
            Text("Identity")
        }
    }

    private var gsCategorySection: some View {
        Section {
            GSCategoryLinkRow(selection: $category.gsCategoryID)
        } header: {
            Text("Grand Shooting link")
        } footer: {
            Text("Optional. Linking this category to a Grand Shooting one lets the app cross-check the link at startup.")
        }
    }

    private var measurementsSection: some View {
        Section {
            ForEach(sortedTemplates) { template in
                MeasurementRowEditor(template: template) {
                    modelContext.delete(template)
                }
            }
            HStack {
                TextField("New measurement (e.g. sleeve)", text: $newMeasurementName)
                    .autocorrectionDisabled()
                Button {
                    addMeasurement()
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
                .disabled(newMeasurementName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Measurements")
        } footer: {
            Text("Names listed in capture order. At capture time you'll place 2 or more points per measurement.")
        }
    }

    private var dangerSection: some View {
        Section {
            Button("Delete category", role: .destructive) {
                showDeleteConfirm = true
            }
        }
    }

    // MARK: - Actions

    private func addMeasurement() {
        let trimmed = newMeasurementName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let order = (category.templates.map(\.order).max() ?? -1) + 1
        let template = MeasurementTemplate(name: trimmed, order: order)
        template.category = category
        modelContext.insert(template)
        newMeasurementName = ""
    }
}

/// Tiny child view so each template gets its own `@Bindable` wrapper —
/// SwiftData needs that for inline `TextField` bindings to work.
private struct MeasurementRowEditor: View {
    @Bindable var template: MeasurementTemplate
    let onDelete: () -> Void

    var body: some View {
        HStack {
            TextField("Measurement", text: $template.name)
                .autocorrectionDisabled()
            Button(role: .destructive) {
                onDelete()
            } label: {
                Image(systemName: "minus.circle")
                    .foregroundStyle(.red)
            }
        }
    }
}
#endif
