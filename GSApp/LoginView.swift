import SwiftUI
import GSAPIClient

/// Dev sign-in screen. Validates `test` / `test2026` against `MockAuthService`
/// and flips `AuthState` to signed-in. No API key here — that's configured
/// in the Settings tab after sign-in.
struct LoginView: View {
    let authState: AuthState

    @State private var username = ""
    @State private var password = ""
    @State private var isSigningIn = false
    @State private var errorMessage: String?

    private let mock = MockAuthService()

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 40)

            // Brand
            VStack(spacing: 12) {
                Image(systemName: "camera.aperture")
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(.tint)
                Text("GS Mobile")
                    .font(.largeTitle.bold())
                Text("Sign in to start scanning")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Credentials
            VStack(spacing: 12) {
                TextField("Username", text: $username)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .textFieldStyle(.roundedBorder)
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .textFieldStyle(.roundedBorder)

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 8)

            Spacer().frame(height: 24)

            // Sign in button
            Button {
                Task { await signIn() }
            } label: {
                if isSigningIn {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                } else {
                    Text("Sign in")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isSigningIn || username.isEmpty || password.isEmpty)

            Spacer()
            Spacer()
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }

    private func signIn() async {
        errorMessage = nil
        isSigningIn = true
        defer { isSigningIn = false }
        do {
            try mock.signIn(username: username, password: password)
            authState.signIn()
        } catch MockAuthService.SignInError.invalidCredentials {
            errorMessage = "Invalid username or password."
        } catch {
            errorMessage = "Sign-in failed: \(error.localizedDescription)"
        }
    }
}
