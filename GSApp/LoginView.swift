import SwiftUI
import GSAPIClient

/// Sign-in screen — OAuth-only.
///
/// Opens the Grand Shooting OAuth flow via
/// `ASWebAuthenticationSession`. The backend's `/auth/exchange`
/// endpoint returns the access + refresh tokens AND the
/// authenticated user's email; the email gates dev-only UI in
/// Settings (the staging-environment picker) so internal staff
/// keep their flexibility while everyone else gets a locked,
/// production-only build.
///
/// The previous `test` / `test2026` dev login was removed — it
/// was a hard-coded credential pair shipping in the binary,
/// which is a known security smell. Internal devs sign in via
/// OAuth like everyone else.
struct LoginView: View {
    let authState: AuthState
    @Bindable var settings: DevSettings

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 40)

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

            OAuthSignInButton(authState: authState, settings: settings)

            Spacer()
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }
}
