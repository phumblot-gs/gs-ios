import SwiftUI
import GSAPIClient
import GSCore

/// Dev login screen. Until the real GS OAuth plugin is wired, signing in
/// boils down to:
///   1. Configure a personal API key in Settings (one-time, persisted
///      in Keychain).
///   2. Type the mock credentials `test` / `test2026` here.
///
/// Will be replaced by `ASWebAuthenticationSession` against the backend
/// `/auth/start` endpoint once the GS plugin is registered.
struct LoginView: View {
    let authState: AuthState
    @Bindable var settings: DevSettings

    @State private var username = ""
    @State private var password = ""
    @State private var isSigningIn = false
    @State private var errorMessage: String?
    @State private var showSettings = false

    private let mock = MockAuthService()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    header

                    if !settings.hasAPIKey {
                        apiKeyMissingCard
                    }

                    credentialsCard

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.subheadline)
                    }

                    signInButton

                    Spacer(minLength: 32)
                }
                .padding(.horizontal, 20)
                .padding(.top, 32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(.systemGroupedBackground))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showSettings) {
                NavigationStack {
                    SettingsTab(authState: authState, settings: settings)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Done") { showSettings = false }
                            }
                        }
                }
            }
        }
    }

    // MARK: - Sub-views

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.aperture")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.tint)
            Text("GS Mobile")
                .font(.largeTitle.bold())
            Text("Sign in to start scanning")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var apiKeyMissingCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("No API key configured", systemImage: "key.slash")
                .font(.headline)
            Text("Add your personal Grand Shooting API key in Settings before signing in.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                showSettings = true
            } label: {
                Label("Open Settings", systemImage: "gearshape")
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(.orange.opacity(0.5), lineWidth: 1)
        )
    }

    private var credentialsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Dev credentials")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            TextField("Username", text: $username)
                .textContentType(.username)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .textFieldStyle(.roundedBorder)
            SecureField("Password", text: $password)
                .textContentType(.password)
                .textFieldStyle(.roundedBorder)
        }
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
    }

    private var signInButton: some View {
        Button {
            Task { await signIn() }
        } label: {
            if isSigningIn {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else {
                Text("Sign in")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(isSigningIn || username.isEmpty || password.isEmpty || !settings.hasAPIKey)
    }

    // MARK: - Sign-in

    private func signIn() async {
        errorMessage = nil
        guard let bearer = settings.apiKey else {
            errorMessage = "Configure your API key in Settings first."
            return
        }
        isSigningIn = true
        defer { isSigningIn = false }
        do {
            let token = try await mock.signIn(
                username: username,
                password: password,
                bearerToken: bearer
            )
            await authState.signIn(token)
        } catch MockAuthService.SignInError.invalidCredentials {
            errorMessage = "Invalid username or password."
        } catch MockAuthService.SignInError.missingBearerToken {
            errorMessage = "API key is empty — reopen Settings."
        } catch {
            errorMessage = "Sign-in failed: \(error.localizedDescription)"
        }
    }
}
