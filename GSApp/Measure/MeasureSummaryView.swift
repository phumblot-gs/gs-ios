#if os(iOS)
import SwiftUI
import GSScanner
import GSAPIClient
import GSCore

/// Final step of the measure flow: review the captured values and attach
/// them to a Grand Shooting reference via `PUT /reference/:id/extra`.
struct MeasureSummaryView: View {
    let settings: DevSettings
    let category: MeasureCategory
    /// Measurements as `name → distance in meters`. Converted to the
    /// configured display unit at save time.
    let measurements: [String: Float]
    let onDone: @MainActor () -> Void

    @State private var resolveSheetVisible = false
    @State private var saving = false
    @State private var saveError: String?
    @State private var savedReferenceRef: String?

    var body: some View {
        Form {
            categorySection
            measurementsSection
            saveSection
            if let savedReferenceRef {
                Section {
                    Label("Saved to \(savedReferenceRef)", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Button("Done") { onDone() }
                }
            }
            if let saveError {
                Section {
                    Label(saveError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }
        }
        .navigationTitle("Validate")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $resolveSheetVisible) {
            NavigationStack {
                ReferenceScanForMeasures(settings: settings) { ref in
                    resolveSheetVisible = false
                    Task { await save(toReference: ref) }
                }
            }
        }
    }

    // MARK: - Sections

    private var categorySection: some View {
        Section("Category") {
            HStack {
                Image(systemName: "tag.fill").foregroundStyle(.tint)
                Text(category.name).font(.headline)
            }
        }
    }

    private var measurementsSection: some View {
        Section("Measurements") {
            ForEach(orderedRows, id: \.name) { row in
                HStack {
                    Text(row.name)
                    Spacer()
                    Text(format(meters: row.meters))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var saveSection: some View {
        if savedReferenceRef == nil {
            Section {
                Button {
                    resolveSheetVisible = true
                } label: {
                    if saving {
                        HStack { ProgressView(); Text("Saving…") }
                    } else {
                        Label("Attach to a reference", systemImage: "link.badge.plus")
                    }
                }
                .disabled(saving)
            } footer: {
                Text("Scan or pick a reference to save these measurements as `extra.measures` on Grand Shooting.")
            }
        }
    }

    private var orderedRows: [(name: String, meters: Float)] {
        let order = category.templates.sorted(by: { $0.order < $1.order }).map(\.name)
        return order.compactMap { name in
            measurements[name].map { (name: name, meters: $0) }
        }
    }

    // MARK: - Formatting

    private func format(meters: Float) -> String {
        let value = settings.measurementUnit.convert(meters: Double(meters))
        return String(format: "%.1f %@", value, settings.measurementUnit.apiSymbol)
    }

    // MARK: - Save

    @MainActor
    private func save(toReference reference: Reference) async {
        guard let referenceID = reference.id else {
            saveError = "Reference is missing a reference_id."
            return
        }
        saving = true
        saveError = nil
        defer { saving = false }

        var payload: [String: ReferenceExtraService.MeasureValue] = [:]
        let unit = settings.measurementUnit
        for (name, meters) in measurements {
            let value = unit.convert(meters: Double(meters))
            // Round to 0.1 to match the displayed precision.
            let rounded = (value * 10).rounded() / 10
            payload[name] = .init(value: rounded, unit: unit.apiSymbol)
        }

        let service = ReferenceExtraService(environment: settings.currentEnvironment)
        do {
            try await service.updateMeasures(referenceID: referenceID, measures: payload)
            savedReferenceRef = reference.ref
        } catch let err as GSHTTPClient.HTTPError {
            saveError = err.userMessage
        } catch {
            saveError = error.localizedDescription
        }
    }
}

// MARK: - Reference selection (embedded scanner + manual entry)

/// Tiny scanner UI used only from the Measure summary screen to grab a
/// reference to attach the measurements to.
private struct ReferenceScanForMeasures: View {
    let settings: DevSettings
    let onResolved: @MainActor (Reference) -> Void

    @State private var manualValue = ""
    @State private var isLookingUp = false
    @State private var error: String?
    @State private var feedback = ScannerFeedback()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .bottom) {
            LiveBarcodeScannerView(resetDelaySeconds: 0.5) { code in
                Task { await resolve(value: code.payload) }
            }
            .ignoresSafeArea()

            VStack(spacing: 10) {
                if isLookingUp {
                    HStack { ProgressView().tint(.white); Text("Looking up…").foregroundStyle(.white) }
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.black.opacity(0.6), in: Capsule())
                }
                if let error {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(8)
                        .background(.thinMaterial, in: Capsule())
                }
                HStack {
                    TextField("Or enter ref / EAN manually", text: $manualValue)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button("Look up") {
                        Task { await resolve(value: manualValue) }
                    }
                    .disabled(manualValue.trimmingCharacters(in: .whitespaces).isEmpty || isLookingUp)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
        .navigationTitle("Attach to reference")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Cancel") { dismiss() }
            }
        }
    }

    @MainActor
    private func resolve(value: String) async {
        guard !isLookingUp else { return }
        isLookingUp = true
        error = nil
        defer { isLookingUp = false }
        feedback.didDetectCode()

        let service = ReferenceLookupService(environment: settings.currentEnvironment)
        do {
            let refs = try await service.lookup(scannedValue: value, by: settings.searchAttribute)
            if let first = refs.first {
                feedback.didFindReference()
                onResolved(first)
            } else {
                feedback.didFailLookup(reason: .notFound)
                error = "No reference for \(value)."
            }
        } catch let err as GSHTTPClient.HTTPError {
            feedback.didFailLookup(reason: .transport)
            error = err.userMessage
        } catch {
            feedback.didFailLookup(reason: .other)
            error = error.localizedDescription
        }
    }
}
#endif
