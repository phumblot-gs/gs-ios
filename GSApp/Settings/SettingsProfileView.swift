import SwiftUI
import GSAPIClient
import GSCore

/// "Profile" page in the Settings menu. The user-facing identity
/// surface: who you're signed in as, which GS account you're working
/// against (when you can access several), preferred UI language,
/// measurement unit, and the sign-out action.
struct SettingsProfileView: View {
    @Bindable var authState: AuthState
    @Bindable var settings: DevSettings
    @Bindable var catalog: CatalogCache
    @Bindable var accountStore: AccountStore

    @State private var showAccountPicker = false

    var body: some View {
        Form {
            headerSection
            if (accountStore.me?.accounts.count ?? 0) >= 2 {
                accountSelectorSection
            }
            languageSection
            measurementSection
            signOutSection
        }
        .navigationTitle("Profile")
        .task {
            if accountStore.me == nil {
                await accountStore.load(settings: settings)
            }
        }
    }

    // MARK: - Header (authenticated identity)

    private var headerSection: some View {
        Section {
            HStack(spacing: 16) {
                avatar
                VStack(alignment: .leading, spacing: 2) {
                    if let firstname = accountStore.me?.firstname, !firstname.isEmpty {
                        Text("Hello, \(firstname)").font(.title3.weight(.semibold))
                    }
                    if let company = accountStore.me?.company {
                        Text(company).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)

            if let company = accountStore.me?.company {
                LabeledContent("Company", value: company)
            }
            if let accountID = accountStore.me?.accountID {
                LabeledContent("Account ID", value: "\(accountID)")
                    .monospacedDigit()
            }
            if let email = accountStore.me?.email, !email.isEmpty {
                LabeledContent("Email", value: email)
            }
            if let role = accountStore.me?.role, !role.isEmpty {
                LabeledContent("Role", value: role.capitalized)
            }
        }
    }

    @ViewBuilder
    private var avatar: some View {
        let url = accountStore.me?.avatar.flatMap(URL.init(string:))
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Image(systemName: "person.crop.circle.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.secondary)
        }
        .frame(width: 56, height: 56)
        .clipShape(Circle())
    }

    // MARK: - GS account selector

    private var accountSelectorSection: some View {
        Section {
            Button {
                showAccountPicker = true
            } label: {
                HStack {
                    Label("Enabled accounts", systemImage: "person.2.badge.gearshape")
                        .foregroundStyle(.primary)
                    Spacer()
                    Text("\(settings.enabledAccountIDs.count)")
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .tint(.primary)
            Button {
                Task { await accountStore.load(settings: settings) }
            } label: {
                HStack {
                    Label("Refresh list", systemImage: "arrow.clockwise")
                    Spacer()
                    if accountStore.isLoading { ProgressView().controlSize(.small) }
                }
            }
            .disabled(accountStore.isLoading)
        } header: {
            Text("Grand Shooting accounts")
        } footer: {
            Text("Choose which Grand Shooting accounts you can work with. Pick the active one from the Scan tab. Stock lookups always stay on your home account.")
        }
        .fullScreenCover(isPresented: $showAccountPicker) {
            AccountPickerSheet(
                title: "Select accounts",
                accounts: accountStore.me?.accounts ?? [],
                recentIDs: [],
                mode: .multi(
                    initial: settings.enabledAccountIDs,
                    onCommit: { commitEnabledAccounts($0) }
                )
            )
        }
    }

    // MARK: - Language

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

    // MARK: - Measurements

    private var measurementSection: some View {
        Section {
            Picker("Unit", selection: $settings.measurementUnit) {
                ForEach(DevSettings.MeasurementUnit.allCases, id: \.rawValue) { unit in
                    Text(unit.displayName).tag(unit)
                }
            }
        } header: {
            Text("Measurements")
        } footer: {
            Text("Unit used when capturing dimensions in the Measures tab and storing them on the reference.")
        }
    }

    // MARK: - Sign out

    private var signOutSection: some View {
        Section {
            Button("Sign out", role: .destructive) {
                Task { await authState.signOut() }
            }
        }
    }

    // MARK: - Actions

    /// Commits the enabled-accounts set. `setEnabledAccounts` reconciles
    /// the active account (it may fall back to the home account if the
    /// previously-active one was disabled); when that happens we refresh
    /// the account-scoped referentials so the app reflects the change.
    private func commitEnabledAccounts(_ ids: Set<Int>) {
        let previousActive = settings.activeAccountID
        settings.setEnabledAccounts(ids)
        if settings.activeAccountID != previousActive {
            Task { await catalog.refresh(environment: settings.currentEnvironment) }
        }
    }
}
