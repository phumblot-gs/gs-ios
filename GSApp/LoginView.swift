import SwiftUI
import GSAPIClient
import GSCore

/// Dev-only login screen used while the real Grand Shooting OAuth plugin
/// is being provisioned. The user enters their personal bearer token once;
/// it lives in the Keychain and is reused across launches.
///
/// This view will be replaced by `ASWebAuthenticationSession` against the
/// backend `/auth/start` endpoint once the GS plugin is registered.
struct LoginView: View {
    let authState: AuthState

    @State private var username = ""
    @State private var password = ""
    @State private var bearerToken = ""
    @State private var isSigningIn = false
    @State private var errorMessage: String?

    private let mock = MockAuthService()

    var body: some View {
        NavigationStack {
            Form {
                Section("Dev credentials") {
                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                }

                Section {
                    SecureField("Paste your personal API key", text: $bearerToken)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Bearer token")
                } footer: {
                    Text("Stored in the iOS Keychain on this device only. Used as `Authorization: Bearer <token>` for every API call until OAuth is wired up.")
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        Task { await signIn() }
                    } label: {
                        if isSigningIn {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Sign in")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(isSigningIn || username.isEmpty || password.isEmpty || bearerToken.isEmpty)
                }
            }
            .navigationTitle("GS Mobile — Dev")
            .onAppear {
                // Pre-fill from environment when running through an Xcode scheme.
                if bearerToken.isEmpty,
                   let envToken = ProcessInfo.processInfo.environment["GS_MOCK_BEARER_TOKEN"] {
                    bearerToken = envToken
                }
            }
        }
    }

    private func signIn() async {
        errorMessage = nil
        isSigningIn = true
        defer { isSigningIn = false }
        do {
            let token = try await mock.signIn(
                username: username,
                password: password,
                bearerToken: bearerToken
            )
            await authState.signIn(token)
        } catch MockAuthService.SignInError.invalidCredentials {
            errorMessage = "Invalid username or password."
        } catch MockAuthService.SignInError.missingBearerToken {
            errorMessage = "Bearer token is required."
        } catch {
            errorMessage = "Sign-in failed: \(error.localizedDescription)"
        }
    }
}
