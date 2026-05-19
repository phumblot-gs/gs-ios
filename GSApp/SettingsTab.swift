import SwiftUI
import GSAPIClient
import GSCore

struct SettingsTab: View {
    @Bindable var authState: AuthState
    @Bindable var settings: DevSettings
    @Bindable var catalog: CatalogCache

    @State private var apiKeyDraft: String = ""
    @State private var apiKeyDirty = false
    @State private var savedToastVisible = false
    @State private var isRefreshing = false

    var body: some View {
        NavigationStack {
            Form {
                workflowSection
                zoneSection
                statusesSection
                batchTypesSection
                searchAttributeSection
                measurementSection
                languageSection
                backendSection
                developmentSection
                accountSection
            }
            .navigationTitle("Settings")
            .onAppear(perform: loadDraft)
            .overlay(alignment: .top) {
                if savedToastVisible {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.thinMaterial, in: Capsule())
                        .foregroundStyle(.green)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.25), value: savedToastVisible)
        }
    }

    // MARK: - Workflow (default status on register, refresh)

    private var workflowSection: some View {
        Section {
            Picker("Default status on register", selection: $settings.defaultStockItemStatusOnRegister) {
                ForEach(StockItemStatus.orderedCases, id: \.rawValue) { status in
                    Text(status.displayName).tag(status.rawValue)
                }
            }
            Button {
                Task { await refreshCatalog() }
            } label: {
                HStack {
                    Label("Refresh catalog", systemImage: "arrow.clockwise")
                    Spacer()
                    if isRefreshing { ProgressView().controlSize(.small) }
                }
            }
            .disabled(isRefreshing)
            if let date = catalog.lastRefreshAt {
                LabeledContent("Last refresh", value: date.formatted(date: .abbreviated, time: .shortened))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Workflow")
        } footer: {
            Text("Default status applied to newly-registered stock items. Refresh pulls fresh zones, categories, and batch types from Grand Shooting.")
        }
    }

    // MARK: - Zone

    @ViewBuilder
    private var zoneSection: some View {
        if catalog.hasZones {
            Section {
                Picker("Active zone", selection: Binding(
                    get: { settings.activeZone ?? catalog.zones.first?.smalltext ?? "" },
                    set: { newValue in settings.activeZone = newValue.isEmpty ? nil : newValue }
                )) {
                    ForEach(catalog.zones) { zone in
                        Text(zone.smalltext).tag(zone.smalltext)
                    }
                }
            } header: {
                Text("Zone")
            } footer: {
                Text("Studio area you are currently working in. Newly-created batches default to this zone.")
            }
        }
    }

    // MARK: - Enabled statuses

    private var statusesSection: some View {
        Section {
            ForEach(StockItemStatus.orderedCases, id: \.rawValue) { status in
                Toggle(isOn: Binding(
                    get: { settings.enabledStockItemStatuses.contains(status.rawValue) },
                    set: { isOn in
                        var set = settings.enabledStockItemStatuses
                        if isOn { set.insert(status.rawValue) } else { set.remove(status.rawValue) }
                        // Default-on-register can't be disabled.
                        set.insert(settings.defaultStockItemStatusOnRegister)
                        settings.enabledStockItemStatuses = set
                    }
                )) {
                    HStack {
                        Text(status.displayName)
                        Spacer()
                        Text("\(status.rawValue)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(status.rawValue == settings.defaultStockItemStatusOnRegister)
            }
        } header: {
            Text("Enabled statuses")
        } footer: {
            Text("Only enabled statuses appear in the change-status picker. The default-on-register status is always enabled.")
        }
    }

    // MARK: - Batch types

    private var batchTypesSection: some View {
        Section {
            if settings.batchTypes.isEmpty {
                Text("No batch types known yet. They populate from your account's batches on the next refresh.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(settings.batchTypes, id: \.self) { type in
                    Text(type)
                }
                .onDelete { indexSet in
                    var types = settings.batchTypes
                    types.remove(atOffsets: indexSet)
                    settings.batchTypes = types
                }
            }
        } header: {
            Text("Batch types")
        } footer: {
            Text("Values offered when creating or editing a batch. Seeded from your existing batches; you can remove unwanted entries here.")
        }
    }

    // MARK: - Search attribute

    private var searchAttributeSection: some View {
        Section {
            Picker("Barcode maps to", selection: $settings.searchAttribute) {
                ForEach(StockService.SearchAttribute.allCases, id: \.rawValue) { attribute in
                    Text(attribute.displayName).tag(attribute)
                }
            }
        } header: {
            Text("Scan lookup")
        } footer: {
            Text("Which catalog attribute the scanned value is looked up against. Use `ean` unless your products are barcoded by their `ref` instead.")
        }
    }

    // MARK: - Language

    private var languageSection: some View {
        Section {
            Picker("Language", selection: $settings.languagePreference) {
                ForEach(DevSettings.LanguagePreference.allCases, id: \.rawValue) { lang in
                    Text(lang.displayName).tag(lang)
                }
            }
        } header: {
            Text("Language")
        } footer: {
            Text("Restart the app for a language change to take full effect.")
        }
    }

    private var measurementSection: some View {
        Section {
            Picker("Unit", selection: $settings.measurementUnit) {
                ForEach(DevSettings.MeasurementUnit.allCases, id: \.rawValue) { unit in
                    Text(unit.displayName).tag(unit)
                }
            }
        } header: {
            Text("Measurements")
        } footer: {
            Text("Unit used when capturing dimensions in the Measures tab and storing them on the reference.")
        }
    }

    // MARK: - Backend

    private var backendSection: some View {
        Section {
            Picker("Environment", selection: $settings.backendEnvironment) {
                ForEach(DevSettings.BackendEnvironment.allCases, id: \.self) { env in
                    Text(env.displayName).tag(env)
                }
            }
            LabeledContent("Mobile backend", value: settings.backendEnvironment.mobileBackendURL.host ?? "—")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text("Backend")
        } footer: {
            Text("Selects which deployed Lambda backend the app talks to.")
        }
    }

    // MARK: - Development (shard + API key)

    private var developmentSection: some View {
        Section {
            HStack {
                Text("Shard")
                TextField("api-19", text: $settings.gsAPIShard)
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
            }
            LabeledContent("API URL", value: settings.currentEnvironment.apiBaseURL.host ?? "—")
                .font(.footnote)
                .foregroundStyle(.secondary)

            SecureField("Personal API key (bearer)", text: $apiKeyDraft)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onChange(of: apiKeyDraft) { _, _ in
                    apiKeyDirty = (apiKeyDraft != (settings.apiKey ?? ""))
                }

            if apiKeyDirty {
                Button("Save API key") { save() }
            } else if settings.hasAPIKey {
                Label("API key configured", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            } else {
                Label("No API key configured", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Grand Shooting API (fallback)")
        } footer: {
            Text("Used as a Bearer token when no OAuth session is active. Stored in the Keychain.")
        }
    }

    private var accountSection: some View {
        Section("Account") {
            Button("Sign out", role: .destructive) {
                Task { await authState.signOut() }
            }
        }
    }

    // MARK: - Actions

    private func loadDraft() {
        apiKeyDraft = settings.apiKey ?? ""
        apiKeyDirty = false
    }

    private func save() {
        settings.apiKey = apiKeyDraft
        apiKeyDirty = false
        withAnimation { savedToastVisible = true }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            await MainActor.run { withAnimation { savedToastVisible = false } }
        }
    }

    private func refreshCatalog() async {
        isRefreshing = true
        defer { isRefreshing = false }
        await catalog.refresh(environment: settings.currentEnvironment)
    }
}
