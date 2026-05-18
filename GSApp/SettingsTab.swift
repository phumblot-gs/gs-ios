import SwiftUI
import GSAPIClient
import GSCore

struct SettingsTab: View {
    @Bindable var authState: AuthState
    @Bindable var settings: DevSettings

    @State private var apiKeyDraft: String = ""
    @State private var apiKeyDirty = false
    @State private var savedToastVisible = false

    var body: some View {
        NavigationStack {
            Form {
                accountSection
                backendSection
                developmentSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
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

    // MARK: - Sections

    private var accountSection: some View {
        Section("Account") {
            HStack {
                Text("Status")
                Spacer()
                Text(authState.isAuthenticated ? "Signed in" : "Not signed in")
                    .foregroundStyle(authState.isAuthenticated ? .green : .secondary)
            }
            if authState.isAuthenticated {
                Button("Sign out", role: .destructive) {
                    Task { await authState.signOut() }
                }
            }
        }
    }

    private var backendSection: some View {
        Section {
            Picker("Environment", selection: $settings.backendEnvironment) {
                ForEach(DevSettings.BackendEnvironment.allCases, id: \.self) { env in
                    Text(env.displayName).tag(env)
                }
            }
            LabeledContent("Mobile backend", value: settings.backendEnvironment.mobileBackendURL.host ?? "—")
                .foregroundStyle(.secondary)
                .font(.footnote)
        } header: {
            Text("Backend")
        } footer: {
            Text("Selects which deployed Lambda backend the app talks to for OAuth (when wired) and packshot processing.")
        }
    }

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
                .foregroundStyle(.secondary)
                .font(.footnote)

            SecureField("Personal API key (bearer)", text: $apiKeyDraft)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onChange(of: apiKeyDraft) { _, _ in
                    apiKeyDirty = (apiKeyDraft != (settings.apiKey ?? ""))
                }

            if apiKeyDirty {
                Button("Save API key") {
                    save()
                }
            } else if settings.hasAPIKey {
                Label("API key configured", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            } else {
                Label("No API key configured", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Grand Shooting API")
        } footer: {
            Text("Both shard and API key are stored locally on this device — the API key in the Keychain. Used for the mock auth flow until the OAuth plugin is wired.")
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

        // If the user is currently signed in via the mock flow, refresh
        // the token in the session so subsequent API calls pick up the new key.
        if authState.isAuthenticated {
            let updated = GSAccessToken(token: apiKeyDraft, scheme: .bearer)
            Task { await authState.signIn(updated) }
        }

        withAnimation { savedToastVisible = true }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            await MainActor.run { withAnimation { savedToastVisible = false } }
        }
    }
}
