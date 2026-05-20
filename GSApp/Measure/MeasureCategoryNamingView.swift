#if os(iOS)
import SwiftUI
import GSAPIClient

/// In-flow naming step for the category creation pipeline. Collects
/// name + optional code + optional GS link + a list of measurement
/// names. Emits a `CategoryDraft` so the calling flow can move to the
/// placement step, where the user will determine each measurement's
/// point count by actually placing points on the "test" product.
///
/// The category isn't persisted yet — saving happens at the end of
/// the placement step, when we also know each template's pointCount
/// and can stamp the illustration onto the category.
struct MeasureCategoryNamingView: View {
    let capturedFrame: CapturedFrame
    let onContinue: @MainActor (CategoryDraft) -> Void
    let onCancel: @MainActor () -> Void

    @State private var name: String = ""
    @State private var code: String = ""
    @State private var gsCategoryID: Int?
    @State private var measurements: [MeasurementDraft] = [MeasurementDraft.blank]

    private struct MeasurementDraft: Identifiable {
        let id = UUID()
        var name: String = ""

        static var blank: MeasurementDraft { MeasurementDraft() }
    }

    var body: some View {
        Form {
            previewSection
            nameSection
            gsCategorySection
            measurementsSection
        }
        .navigationTitle("New category")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") { onCancel() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Continue") { continueToPlacement() }
                    .disabled(!canContinue)
            }
        }
    }

    private var canContinue: Bool {
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
            Text("The captured photo will become the category's illustration after you've taken the test measurements.")
        }
    }

    private var nameSection: some View {
        Section {
            TextField("Category name (e.g. Dress, Shirt, Game box)", text: $name)
                .autocorrectionDisabled()
            TextField("Code (optional, e.g. ERP / catalog code)", text: $code)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        } header: {
            Text("Name")
        } footer: {
            Text("The code lets you link this category to your internal coding system. It's free-form and optional.")
        }
    }

    private var gsCategorySection: some View {
        Section {
            GSCategoryLinkRow(selection: $gsCategoryID)
        } header: {
            Text("Grand Shooting link")
        } footer: {
            Text("Optional. Links this category to a Grand Shooting catalog category so the app can cross-check the link at startup.")
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
            Text("List the dimensions you want to capture. At the next step you'll place the points for each measurement on the test product — the number of points you place becomes the schema for this category.")
        }
    }

    // MARK: - Continue

    private func continueToPlacement() {
        let trimmedCode = code.trimmingCharacters(in: .whitespaces)
        let names = measurements
            .map { $0.name.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let draft = CategoryDraft(
            name: name.trimmingCharacters(in: .whitespaces),
            code: trimmedCode.isEmpty ? nil : trimmedCode,
            gsCategoryID: gsCategoryID,
            measurementNames: names
        )
        onContinue(draft)
    }
}

/// In-flight category description awaiting persistence. Created by
/// `MeasureCategoryNamingView`; consumed by the placement step which
/// then assembles the actual `MeasureCategory` once each template's
/// pointCount is known.
struct CategoryDraft: Sendable {
    let name: String
    let code: String?
    let gsCategoryID: Int?
    let measurementNames: [String]
}
#endif
