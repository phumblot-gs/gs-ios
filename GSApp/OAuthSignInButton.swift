import SwiftUI
import AuthenticationServices
import GSAPIClient
import GSCore

/// "Sign in with Grand Shooting" CTA. Opens an ASWebAuthenticationSession
/// pointed at the backend's `/auth/start`, intercepts the
/// `gsmobile://auth/done?session_id=…` callback, and finishes the OAuth
/// dance through `OAuthSignInService`.
struct OAuthSignInButton: View {
    let authState: AuthState
    let settings: DevSettings

    @Environment(\.webAuthenticationSession) private var webAuthSession
    @State private var isSigningIn = false
    @State private var errorMessage: String?

    private static let callbackScheme = "gsmobile"

    var body: some View {
        VStack(spacing: 8) {
            Button {
                Task { await signIn() }
            } label: {
                HStack {
                    if isSigningIn {
                        ProgressView()
                    } else {
                        Image(systemName: "camera.aperture")
                    }
                    Text("Sign in with Grand Shooting")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 24)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isSigningIn)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @MainActor
    private func signIn() async {
        errorMessage = nil
        isSigningIn = true
        defer { isSigningIn = false }

        let env = settings.currentEnvironment
        do {
            let callbackURL = try await webAuthSession.authenticate(
                using: env.oauthEntryURL,
                callback: .customScheme(Self.callbackScheme),
                additionalHeaderFields: [:]
            )
            let service = OAuthSignInService(environment: env)
            let result = try await service.completeSignIn(callbackURL: callbackURL)
            authState.signIn(email: result.email)
            // Force the production backend for everyone outside
            // Grand Shooting. Staff (@grand-shooting.com) keeps
            // whatever they had picked in Settings.
            if !authState.isGrandShootingStaff {
                settings.backendEnvironment = .production
            }
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            // User tapped Cancel in Safari — silent, no error display.
            return
        } catch OAuthSignInService.SignInError.missingSessionId {
            errorMessage = "OAuth callback didn't include a session id."
        } catch let OAuthSignInService.SignInError.backend(.http(status, body)) {
            errorMessage = "Backend returned \(status). \(body ?? "")"
        } catch OAuthSignInService.SignInError.backend(.transport) {
            errorMessage = "Couldn't reach the mobile backend. Check connectivity."
        } catch {
            errorMessage = "Sign-in failed: \(error.localizedDescription)"
        }
    }
}
