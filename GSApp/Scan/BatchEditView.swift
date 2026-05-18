import SwiftUI
import GSAPIClient
import GSCore

/// Edit a batch's smalltext / code / type / zone. Lives in a sheet,
/// dismisses on save.
struct BatchEditView: View {
    let original: Batch
    let settings: DevSettings
    let onSaved: @MainActor (Batch) -> Void

    @State private var smalltext: String
    @State private var code: String
    @State private var type: String
    @State private var zoneID: Int?
    @State private var isSaving = false
    @State private var errorMessage: String?

    @Environment(\.dismiss) private var dismiss

    init(batch: Batch, settings: DevSettings, onSaved: @escaping @MainActor (Batch) -> Void) {
        self.original = batch
        self.settings = settings
        self.onSaved = onSaved
        _smalltext = State(initialValue: batch.smalltext ?? "")
        _code = State(initialValue: batch.code ?? "")
        _type = State(initialValue: batch.type ?? "")
        _zoneID = State(initialValue: batch.zoneID)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Label") {
                    TextField("Label", text: $smalltext)
                }
                Section("Code") {
                    HStack {
                        TextField("Code (barcode)", text: $code)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .keyboardType(.numbersAndPunctuation)
                        Button {
                            code = generateBarcode()
                        } label: {
                            Image(systemName: "wand.and.stars")
                        }
                        .accessibilityLabel("Generate random code")
                    }
                }
                Section("Type") {
                    BatchTypePicker(selection: $type, settings: settings)
                }
                if CatalogCache.shared.hasZones {
                    Section("Zone") {
                        Picker("Zone", selection: Binding(
                            get: { zoneID ?? -1 },
                            set: { zoneID = $0 >= 0 ? $0 : nil }
                        )) {
                            Text("None").tag(-1)
                            ForEach(CatalogCache.shared.zones) { zone in
                                Text(zone.smalltext ?? "Zone #\(zone.id)").tag(zone.id)
                            }
                        }
                    }
                }
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("Edit batch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") {
                            Task { await save() }
                        }
                        .disabled(smalltext.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
    }

    private func save() async {
        errorMessage = nil
        isSaving = true
        defer { isSaving = false }
        let payload = BatchService.UpdatePayload(
            smalltext: smalltext,
            code: code.isEmpty ? nil : code,
            type: type.isEmpty ? nil : type,
            zoneID: zoneID
        )
        let service = BatchService(environment: settings.currentEnvironment)
        do {
            let updated = try await service.update(id: original.id, payload: payload)
            // If the user introduced a new type, remember it in settings.
            if !type.isEmpty, !settings.batchTypes.contains(type) {
                settings.batchTypes.append(type)
            }
            onSaved(updated)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Picker that lists known batch types from `DevSettings.batchTypes` plus
/// an inline "Other…" entry that captures a free-form new type.
struct BatchTypePicker: View {
    @Binding var selection: String
    let settings: DevSettings

    @State private var showOther = false
    @State private var otherDraft = ""

    private var knownTypes: [String] { settings.batchTypes }

    var body: some View {
        Group {
            Picker("Type", selection: Binding(
                get: { knownTypes.contains(selection) || selection.isEmpty ? selection : "" },
                set: { newValue in
                    if newValue.isEmpty {
                        // Sentinel for "Other…" — opens the inline editor.
                        showOther = true
                    } else {
                        selection = newValue
                        showOther = false
                    }
                }
            )) {
                Text("—").tag("")
                ForEach(knownTypes, id: \.self) { type in
                    Text(type).tag(type)
                }
                Text("Other…").tag("__OTHER__")
            }
            if showOther {
                TextField("New type", text: $otherDraft)
                    .autocorrectionDisabled()
                Button("Use type") {
                    selection = otherDraft.trimmingCharacters(in: .whitespaces)
                    showOther = false
                    otherDraft = ""
                }
                .disabled(otherDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear {
            if !selection.isEmpty && !knownTypes.contains(selection) {
                showOther = true
                otherDraft = selection
            }
        }
    }
}

/// Random EAN-13 — useful when creating a batch on the fly and you want
/// a barcode you can stick on the box later.
func generateBarcode() -> String {
    let digits = (0..<12).map { _ in Int.random(in: 0...9) }
    var sum = 0
    for (index, digit) in digits.enumerated() {
        sum += digit * (index % 2 == 0 ? 1 : 3)
    }
    let checksum = (10 - sum % 10) % 10
    return (digits + [checksum]).map(String.init).joined()
}
