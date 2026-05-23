import SwiftUI
import GSAPIClient
import GSCore

/// "Profile" page in the Settings menu. The user-facing identity
/// surface: preferred UI language and the sign-out action.
struct SettingsProfileView: View {
    @Bindable var authState: AuthState
    @Bindable var settings: DevSettings

    var body: some View {
        Form {
            languageSection
            accountSection
        }
        .navigationTitle("Profile")
    }

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

    private var accountSection: some View {
        Section("Account") {
            Button("Sign out", role: .destructive) {
                Task { await authState.signOut() }
            }
        }
    }
}
