#if os(iOS)
import SwiftUI
import SwiftData
import GSAPIClient

/// Form to define a brand-new `MeasureCategory` using the captured frame
/// as the example. The user names the category and declares one or more
/// `MeasurementTemplate`s — each a name (e.g. "manche") plus an ordered
/// list of point labels (e.g. ["col", "emmanchure", "bout"]).
struct MeasureCategoryCreateView: View {
    let settings: DevSettings
    let capturedFrame: CapturedFrame
    let newEmbedding: Data?
    let onCreated: @MainActor (MeasureCategory) -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var templates: [TemplateDraft] = [TemplateDraft.blank]
    @State private var isSaving = false

    private struct TemplateDraft: Identifiable {
        let id = UUID()
        var name: String = ""
        var labels: [String] = ["", ""]

        static var blank: TemplateDraft { TemplateDraft() }
    }

    var body: some View {
        Form {
            previewSection
            nameSection
            ForEach($templates) { $template in
                templateSection($template)
            }
            addTemplateSection
        }
        .navigationTitle("New category")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if isSaving {
                    ProgressView()
                } else {
                    Button("Create") { save() }
                        .disabled(!canSave)
                }
            }
        }
    }

    private var canSave: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        let cleanTemplates = templates.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !cleanTemplates.isEmpty else { return false }
        return cleanTemplates.allSatisfy { template in
            template.labels.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count >= 2
        }
    }

    // MARK: - Sections

    private var previewSection: some View {
        Section {
            Image(uiImage: capturedFrame.image)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 180)
                .cornerRadius(12)
        } footer: {
            Text("This image becomes the visual reference for this category. Future captures matching it will suggest this category automatically.")
        }
    }

    private var nameSection: some View {
        Section {
            TextField("Category name (e.g. Dress, Shirt, Game box)", text: $name)
                .autocorrectionDisabled()
        } header: {
            Text("Name")
        }
    }

    private func templateSection(_ binding: Binding<TemplateDraft>) -> some View {
        Section {
            TextField("Measurement name (e.g. sleeve)", text: binding.name)
                .autocorrectionDisabled()
            ForEach(binding.labels.indices, id: \.self) { index in
                HStack {
                    Text("Point \(index + 1)")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    TextField("Label (e.g. collar)", text: binding.labels[index])
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                }
            }
            HStack(spacing: 12) {
                Button {
                    binding.wrappedValue.labels.append("")
                } label: {
                    Label("Add point", systemImage: "plus.circle")
                }
                Spacer()
                if binding.wrappedValue.labels.count > 2 {
                    Button(role: .destructive) {
                        binding.wrappedValue.labels.removeLast()
                    } label: {
                        Label("Remove last", systemImage: "minus.circle")
                    }
                }
            }
        } header: {
            Text("Measurement")
        } footer: {
            Text("Distance = sum of segments between successive points. Minimum 2 points (1 segment).")
        }
    }

    private var addTemplateSection: some View {
        Section {
            Button {
                templates.append(TemplateDraft.blank)
            } label: {
                Label("Add another measurement", systemImage: "plus.circle.fill")
            }
            if templates.count > 1 {
                Button(role: .destructive) {
                    templates.removeLast()
                } label: {
                    Label("Remove last measurement", systemImage: "trash")
                }
            }
        }
    }

    // MARK: - Save

    private func save() {
        isSaving = true
        let category = MeasureCategory(
            name: name.trimmingCharacters(in: .whitespaces),
            imageEmbedding: newEmbedding,
            exampleImageData: capturedFrame.image.jpegData(compressionQuality: 0.8)
        )
        modelContext.insert(category)
        var order = 0
        for draft in templates {
            let cleanName = draft.name.trimmingCharacters(in: .whitespaces)
            guard !cleanName.isEmpty else { continue }
            let cleanLabels = draft.labels
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard cleanLabels.count >= 2 else { continue }
            let template = MeasurementTemplate(name: cleanName, pointLabels: cleanLabels, order: order)
            template.category = category
            modelContext.insert(template)
            order += 1
        }
        do {
            try modelContext.save()
            onCreated(category)
        } catch {
            // Best-effort: surface via a print for now. Phase 5 will add
            // proper error UI when we wire the API save.
            print("[MeasureCategoryCreateView] save failed: \(error)")
        }
        isSaving = false
    }
}
#endif
