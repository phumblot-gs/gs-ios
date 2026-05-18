import SwiftUI
import GSAPIClient
import GSCore

/// Create a new batch. Same field set as `BatchEditView` minus the
/// pre-existing values. Default zone = currently active.
struct BatchCreateView: View {
    let settings: DevSettings
    let onCreated: @MainActor (Batch) -> Void

    @State private var smalltext: String = ""
    @State private var code: String = ""
    @State private var type: String = ""
    @State private var zone: String?
    @State private var isSaving = false
    @State private var errorMessage: String?

    @Environment(\.dismiss) private var dismiss

    init(settings: DevSettings, onCreated: @escaping @MainActor (Batch) -> Void) {
        self.settings = settings
        self.onCreated = onCreated
        _zone = State(initialValue: settings.activeZone)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Label") {
                    TextField("Label", text: $smalltext)
                }
                Section {
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
                } header: {
                    Text("Code")
                } footer: {
                    Text("Optional. Tap the wand to generate a random EAN-13 you can print and stick on the box.")
                }
                Section("Type") {
                    BatchTypePicker(selection: $type, settings: settings)
                }
                if CatalogCache.shared.hasZones {
                    Section("Zone") {
                        Picker("Zone", selection: Binding(
                            get: { zone ?? "" },
                            set: { zone = $0.isEmpty ? nil : $0 }
                        )) {
                            Text("None").tag("")
                            ForEach(CatalogCache.shared.zones) { z in
                                Text(z.smalltext).tag(z.smalltext)
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
            .navigationTitle("New batch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Create") {
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
        let payload = BatchService.CreatePayload(
            smalltext: smalltext,
            code: code.isEmpty ? nil : code,
            type: type.isEmpty ? nil : type,
            zone: zone
        )
        let service = BatchService(environment: settings.currentEnvironment)
        do {
            let created = try await service.create(payload)
            if !type.isEmpty, !settings.batchTypes.contains(type) {
                settings.batchTypes.append(type)
            }
            onCreated(created)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
