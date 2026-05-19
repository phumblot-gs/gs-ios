#if os(iOS)
import SwiftUI
import SwiftData
import GSAPIClient

/// Form to define a brand-new `MeasureCategory` using the captured frame
/// as the example. The user names the category and lists the
/// measurements they want to capture for it (e.g. "manche", "buste",
/// "hauteur"). Each measurement is just a semantic name — the number of
/// points placed for it is decided at capture time.
struct MeasureCategoryCreateView: View {
    let settings: DevSettings
    let capturedFrame: CapturedFrame
    let newEmbedding: Data?
    let onCreated: @MainActor (MeasureCategory) -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var measurements: [MeasurementDraft] = [MeasurementDraft.blank]
    @State private var isSaving = false

    private struct MeasurementDraft: Identifiable {
        let id = UUID()
        var name: String = ""

        static var blank: MeasurementDraft { MeasurementDraft() }
    }

    var body: some View {
        Form {
            previewSection
            nameSection
            measurementsSection
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
        let valid = measurements.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
        return !valid.isEmpty
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

    private var measurementsSection: some View {
        Section {
            ForEach($measurements) { $measurement in
                TextField("Measurement name (e.g. sleeve)", text: $measurement.name)
                    .autocorrectionDisabled()
            }
            .onDelete { offsets in
                measurements.remove(atOffsets: offsets)
            }
            Button {
                measurements.append(MeasurementDraft.blank)
            } label: {
                Label("Add a measurement", systemImage: "plus.circle.fill")
            }
        } header: {
            Text("Measurements")
        } footer: {
            Text("List the dimensions you want to capture for this category. At capture time you'll place 2 or more points per measurement; the distance is the sum of the segments.")
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
        for draft in measurements {
            let cleanName = draft.name.trimmingCharacters(in: .whitespaces)
            guard !cleanName.isEmpty else { continue }
            let template = MeasurementTemplate(name: cleanName, order: order)
            template.category = category
            modelContext.insert(template)
            order += 1
        }
        do {
            try modelContext.save()
            onCreated(category)
        } catch {
            print("[MeasureCategoryCreateView] save failed: \(error)")
        }
        isSaving = false
    }
}
#endif
