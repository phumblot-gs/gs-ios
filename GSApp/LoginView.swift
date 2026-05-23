import SwiftUI
import GSAPIClient

/// Sign-in screen — OAuth-only.
///
/// Opens the Grand Shooting OAuth flow via
/// `ASWebAuthenticationSession`. The backend's `/auth/exchange`
/// endpoint returns the access + refresh tokens AND the
/// authenticated user's account id; the account id gates
/// dev-only UI in Settings (the staging-environment picker) so
/// internal staff keep their flexibility while everyone else
/// gets a locked, production-only build.
///
/// Hidden easter egg: a **5-second long press on the logo**
/// toggles between production and staging *before sign-in*. Lets
/// staff devices that need to authenticate against the staging
/// backend do so without shipping a separate build. The
/// post-sign-in clamp still applies for non-staff users — so if
/// a curious user discovers the trick and toggles to staging,
/// they'll be forced back to production the moment they
/// actually sign in.
struct LoginView: View {
    let authState: AuthState
    @Bindable var settings: DevSettings

    @State private var toggleTriggerCount = 0

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 40)

            VStack(spacing: 12) {
                Image(systemName: "camera.aperture")
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(.tint)
                    .contentShape(Rectangle())
                    .onLongPressGesture(minimumDuration: 5.0) {
                        toggleTestMode()
                    }
                    .accessibilityHint("Long-press 5 seconds to toggle staging mode")
                Text("GS Mobile")
                    .font(.largeTitle.bold())
                Text("Sign in to start scanning")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if settings.backendEnvironment == .staging {
                    Label("Test mode · staging", systemImage: "testtube.2")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.orange.opacity(0.18), in: Capsule())
                        .foregroundStyle(.orange)
                        .padding(.top, 6)
                        .transition(.opacity.combined(with: .scale))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: settings.backendEnvironment)

            Spacer()

            OAuthSignInButton(authState: authState, settings: settings)

            Spacer()
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .sensoryFeedback(.success, trigger: toggleTriggerCount)
    }

    private func toggleTestMode() {
        switch settings.backendEnvironment {
        case .production:
            settings.backendEnvironment = .staging
        case .staging:
            settings.backendEnvironment = .production
        }
        toggleTriggerCount += 1
    }
}
