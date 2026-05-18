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

/// Picker for the batch `type` attribute. Lists the known types from
/// `DevSettings.batchTypes` plus a "—" no-type option and an inline
/// "Other…" entry that switches to a free-text field.
///
/// Caveats handled here:
/// - The current `selection` is always visible in the picker even when
///   it isn't (yet) in the known list — otherwise the user picks the
///   value, dismisses the editor, and the picker silently appears to
///   reset.
/// - "Other…" uses a sentinel tag distinct from the empty string so
///   choosing "—" doesn't accidentally open the editor.
/// - "Use type" appends the new value to `settings.batchTypes` right
///   away so the next selection sees it as a known option.
struct BatchTypePicker: View {
    @Binding var selection: String
    @Bindable var settings: DevSettings

    @State private var showOther = false
    @State private var otherDraft = ""

    private let otherSentinel = "__BATCH_TYPE_OTHER__"

    private var knownTypes: [String] { settings.batchTypes }

    var body: some View {
        Picker("Type", selection: Binding<String>(
            get: { showOther ? otherSentinel : selection },
            set: { newValue in
                if newValue == otherSentinel {
                    showOther = true
                    otherDraft = selection
                } else {
                    showOther = false
                    selection = newValue
                }
            }
        )) {
            Text("—").tag("")
            // Surface the current selection even if it's not (yet) in
            // the known list — covers existing batches whose `type`
            // value isn't registered locally.
            if !selection.isEmpty && !knownTypes.contains(selection) {
                Text(selection).tag(selection)
            }
            ForEach(knownTypes, id: \.self) { type in
                Text(type).tag(type)
            }
            Text("Other…").tag(otherSentinel)
        }

        if showOther {
            HStack {
                TextField("New type", text: $otherDraft)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Use") {
                    let trimmed = otherDraft.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        selection = trimmed
                        if !settings.batchTypes.contains(trimmed) {
                            settings.batchTypes.append(trimmed)
                        }
                    }
                    showOther = false
                    otherDraft = ""
                }
                .disabled(otherDraft.trimmingCharacters(in: .whitespaces).isEmpty)
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
