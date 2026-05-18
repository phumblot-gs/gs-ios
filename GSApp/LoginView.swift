import SwiftUI
import GSAPIClient

/// Sign-in screen.
///
/// Two entry paths:
///  - **Sign in with Grand Shooting** (primary): opens the real OAuth flow
///    via `ASWebAuthenticationSession`. Once the backend issues an access
///    token, the user is signed in and all API calls authenticate against
///    that token.
///  - **Dev credentials** (fallback): the existing `test` / `test2026` mock.
///    Useful when working offline or when the GS plugin isn't reachable.
///    Requires a personal API key configured in Settings (post sign-in)
///    for the GS API calls to succeed.
struct LoginView: View {
    let authState: AuthState
    @Bindable var settings: DevSettings

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

            // Primary: OAuth
            OAuthSignInButton(authState: authState, settings: settings)

            // Divider
            HStack {
                Rectangle().fill(.tertiary).frame(height: 1)
                Text("OR")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                Rectangle().fill(.tertiary).frame(height: 1)
            }
            .padding(.vertical, 24)

            // Fallback: dev credentials
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

                Button {
                    Task { await signInWithMock() }
                } label: {
                    if isSigningIn {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .frame(height: 24)
                    } else {
                        Text("Sign in with dev credentials")
                            .font(.subheadline)
                            .frame(maxWidth: .infinity)
                            .frame(height: 24)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(isSigningIn || username.isEmpty || password.isEmpty)
            }

            Spacer()
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }

    private func signInWithMock() async {
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
