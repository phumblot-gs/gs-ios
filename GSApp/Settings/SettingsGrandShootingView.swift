import SwiftUI
import GSAPIClient
import GSCore

/// "Grand Shooting" page in the Settings menu. Holds everything
/// that talks to the GS platform itself: the technical-views
/// shooting method, the backend environment selector, and the
/// fallback API-key form.
struct SettingsGrandShootingView: View {
    @Bindable var settings: DevSettings
    @Bindable var catalog: CatalogCache

    @State private var apiKeyDraft: String = ""
    @State private var apiKeyDirty = false
    @State private var savedToastVisible = false
    @State private var shootingMethods: [ShootingMethod] = []
    @State private var isLoadingShootingMethods = false
    @State private var shootingMethodsError: String?

    var body: some View {
        Form {
            techViewsSection
            backendSection
            developmentSection
        }
        .navigationTitle("Grand Shooting")
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

    // MARK: - Technical views (shooting method)

    private var techViewsSection: some View {
        Section {
            if isLoadingShootingMethods && shootingMethods.isEmpty {
                HStack { ProgressView().controlSize(.small); Text("Loading shooting methods…") }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if let err = shootingMethodsError, shootingMethods.isEmpty {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                Button("Retry") { Task { await loadShootingMethods() } }
            } else {
                Picker("Shooting method", selection: shootingMethodBinding) {
                    Text("None").tag(Int?.none)
                    ForEach(shootingMethods) { method in
                        Text(method.name).tag(Int?.some(method.id))
                    }
                }
                Button {
                    Task { await loadShootingMethods() }
                } label: {
                    HStack {
                        Label("Refresh list", systemImage: "arrow.clockwise")
                        Spacer()
                        if isLoadingShootingMethods { ProgressView().controlSize(.small) }
                    }
                }
                .disabled(isLoadingShootingMethods)
            }
        } header: {
            Text("Technical views")
        } footer: {
            Text("Picks the Grand Shooting shooting method the technical-view uploads are scoped to. The Photo tab is disabled until a method is selected.")
        }
        .task(id: settings.apiKeyRevision) {
            if shootingMethods.isEmpty {
                await loadShootingMethods()
            }
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

    // MARK: - API key (fallback)

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

    // MARK: - Bindings + actions

    private var shootingMethodBinding: Binding<Int?> {
        Binding(
            get: { settings.techViewsShootingMethodID },
            set: { newValue in
                settings.techViewsShootingMethodID = newValue
                if let id = newValue,
                   let match = shootingMethods.first(where: { $0.id == id }) {
                    settings.techViewsShootingMethodName = match.name
                } else {
                    settings.techViewsShootingMethodName = nil
                }
            }
        )
    }

    private func loadShootingMethods() async {
        isLoadingShootingMethods = true
        shootingMethodsError = nil
        defer { isLoadingShootingMethods = false }
        let service = ShootingMethodService(environment: settings.currentEnvironment)
        do {
            let methods = try await service.list()
            shootingMethods = methods.sorted(by: { $0.name < $1.name })
            if let id = settings.techViewsShootingMethodID,
               let match = methods.first(where: { $0.id == id }) {
                settings.techViewsShootingMethodName = match.name
            }
        } catch let err as GSHTTPClient.HTTPError {
            shootingMethodsError = err.userMessage
        } catch {
            shootingMethodsError = error.localizedDescription
        }
    }

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
}
