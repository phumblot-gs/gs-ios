import SwiftUI
import GSAPIClient
import GSCore

/// Root of the Settings tab. Acts as the entry list — like the
/// system Settings.app — and pushes a topic-specific Form for
/// each tap. Knobs that used to be flat under a single Form now
/// live in `SettingsScannerView` / `SettingsPhotoView` /
/// `SettingsGrandShootingView` / `SettingsProfileView`.
struct SettingsTab: View {
    @Bindable var authState: AuthState
    @Bindable var settings: DevSettings
    @Bindable var catalog: CatalogCache
    @Bindable var accountStore: AccountStore
    @Bindable var syncRepository: SettingsSyncRepository

    var body: some View {
        NavigationStack {
            List {
                if settings.activeAccountID != nil {
                    ActiveAccountBar(settings: settings)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 12, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                NavigationLink {
                    SettingsScannerView(settings: settings, catalog: catalog)
                } label: {
                    menuRow(title: "Scanner", systemImage: "barcode.viewfinder")
                }
                NavigationLink {
                    SettingsPhotoView(settings: settings)
                } label: {
                    menuRow(title: "Photo", systemImage: "camera")
                }
                NavigationLink {
                    SettingsReferencesView(settings: settings)
                } label: {
                    menuRow(title: "References", systemImage: "tag")
                }
                NavigationLink {
                    SettingsGrandShootingView(authState: authState, settings: settings, catalog: catalog)
                } label: {
                    menuRow(title: "Grand Shooting", systemImage: "building.2")
                }
                NavigationLink {
                    SettingsSyncView(
                        settings: settings,
                        accountStore: accountStore,
                        repository: syncRepository
                    )
                } label: {
                    menuRow(title: "Sync", systemImage: "icloud")
                }
                NavigationLink {
                    SettingsProfileView(authState: authState, settings: settings, catalog: catalog, accountStore: accountStore)
                } label: {
                    menuRow(title: "Profile", systemImage: "person.crop.circle")
                }
            }
            .navigationTitle("Settings")
        }
    }

    private func menuRow(title: LocalizedStringKey, systemImage: String) -> some View {
        Label {
            Text(title)
                .font(.body)
        } icon: {
            Image(systemName: systemImage)
                .frame(width: 28)
        }
        .padding(.vertical, 2)
    }
}
