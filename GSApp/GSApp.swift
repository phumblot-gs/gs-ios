import SwiftUI
import SwiftData
import GSAPIClient
import GSCore

@main
struct GSApp: App {
    @State private var authState = AuthState()
    @State private var settings = DevSettings.shared
    @State private var catalog = CatalogCache.shared
    @State private var accountStore = AccountStore()
    @State private var appNavigation = AppNavigation()
    @State private var syncRepository: SettingsSyncRepository = {
        let settings = DevSettings.shared
        return SettingsSyncRepository(
            service: AccountSettingsService(environment: settings.currentEnvironment),
            settings: settings
        )
    }()
    private let logger = GSLogger(category: "App")

    init() {
        logger.info("GS Mobile launching")
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if authState.isSignedIn {
                    RootView(authState: authState, settings: settings, catalog: catalog, accountStore: accountStore, appNavigation: appNavigation, syncRepository: syncRepository)
                } else {
                    LoginView(authState: authState, settings: settings)
                }
            }
            // Re-bind the sync service when the user flips between
            // staging and production from the easter egg, so pushes
            // hit the right mobile backend.
            .task(id: settings.backendEnvironment) {
                syncRepository.updateService(
                    AccountSettingsService(environment: settings.currentEnvironment)
                )
            }
            // Refresh the catalog (zones, categories, batch types) any time
            // we become signed in (cold launch with a persisted session, or
            // a fresh login). The view stays interactive while the refresh
            // runs in the background.
            .task(id: authState.isSignedIn) {
                if authState.isSignedIn {
                    // Belt for the suspenders: clamp confirmed
                    // non-staff users to production on every
                    // launch. We leave `.unknown` users alone so a
                    // staff device that authenticated against
                    // staging through the easter egg keeps its
                    // backend — the GS proxy doesn't return
                    // identity yet, so today everyone is
                    // `.unknown` until the Lambda patch lands.
                    if authState.staffStatus == .notStaff,
                       settings.backendEnvironment != .production {
                        settings.backendEnvironment = .production
                    }
                    // Resolve the user's accounts + apply the active
                    // one (shard + account_id header + per-account
                    // settings) BEFORE the catalog refresh, so the
                    // refresh targets the right account.
                    await accountStore.load(settings: settings)
                    await catalog.refresh(environment: settings.currentEnvironment)
                    // Auto-pull central settings once per 24h, admin-only.
                    // Skipped silently for non-admins to avoid hitting
                    // the backend 403 on every sign-in.
                    if accountStore.me?.isAdmin == true, syncRepository.shouldAutoPull() {
                        await syncRepository.pull()
                        syncRepository.markAutoPulled()
                    }
                }
            }
            .onOpenURL { url in
                // Deep-link callback from `ASWebAuthenticationSession` /
                // backend OAuth flow: `gsmobile://auth/done?session_id=...`
                AuthDeepLinkHandler.handle(url)
            }
        }
        // SwiftData container for the Measures feature. Schema kept local
        // to the app target for now — we'll move it to a backend-synced
        // store when categories need to be shared across team members.
        .modelContainer(for: [
            MeasureCategory.self,
            MeasurementTemplate.self,
            LearnedPictogram.self
        ])
    }
}

struct RootView: View {
    let authState: AuthState
    @Bindable var settings: DevSettings
    @Bindable var catalog: CatalogCache
    @Bindable var accountStore: AccountStore
    @Bindable var appNavigation: AppNavigation
    @Bindable var syncRepository: SettingsSyncRepository

    @Environment(\.modelContext) private var modelContext
    @State private var orphanReport: OrphanReport?

    var body: some View {
        TabView(selection: $appNavigation.selectedTab) {
            ScanTab(settings: settings)
                .tabItem { Label("Scan", systemImage: "barcode.viewfinder") }
                .tag(AppNavigation.AppTab.scan)
            PhotoTab(settings: settings)
                .tabItem { Label("Photo", systemImage: "camera") }
                .tag(AppNavigation.AppTab.photo)
            if settings.isMeasureEnabled {
                MeasureTab(settings: settings)
                    .tabItem { Label("Measures", systemImage: "ruler") }
                    .tag(AppNavigation.AppTab.measure)
            }
            HistoryTab(settings: settings)
                .tabItem { Label("History", systemImage: "clock") }
                .tag(AppNavigation.AppTab.history)
            SettingsTab(authState: authState, settings: settings, catalog: catalog, accountStore: accountStore, syncRepository: syncRepository)
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppNavigation.AppTab.settings)
        }
        .environment(appNavigation)
        .overlay(alignment: .top) {
            BackendStatusBanner(
                environment: settings.currentEnvironment,
                environmentName: settings.backendEnvironment.rawValue
            )
            .padding(.top, 4)
        }
        // Apply the user's language preference to the whole UI.
        // `.system` falls through to the OS default. Setting
        // `\.locale` on the root view re-renders any `Text(...)`
        // and `String(localized:)` against the chosen language's
        // xcstrings entries.
        .environment(\.locale, currentLocale)
        // After each catalog refresh we double-check that every
        // `MeasureCategory.gsCategoryID` still resolves to a known GS
        // category. Dangling links get listed in an alert and cleared
        // when the user dismisses it.
        .task(id: catalog.lastRefreshAt) {
            guard catalog.lastRefreshAt != nil, !catalog.categories.isEmpty else { return }
            let orphans = MeasureOrphanChecker.findOrphans(modelContext: modelContext, catalog: catalog)
            if !orphans.isEmpty {
                orphanReport = OrphanReport(orphans: orphans)
            }
        }
        .alert(
            "Linked Grand Shooting categories no longer exist",
            isPresented: Binding(
                get: { orphanReport != nil },
                set: { if !$0 { orphanReport = nil } }
            ),
            actions: {
                Button("OK") {
                    if let report = orphanReport {
                        MeasureOrphanChecker.clearLinks(on: report.orphans, modelContext: modelContext)
                    }
                    orphanReport = nil
                }
            },
            message: { Text(orphanReport?.message ?? "") }
        )
    }

    /// Locale derived from the user's language preference. Drives
    /// the `\.locale` environment so the UI re-renders against the
    /// matching xcstrings entries when the picker changes.
    private var currentLocale: Locale {
        if let identifier = settings.languagePreference.localeIdentifier {
            return Locale(identifier: identifier)
        }
        return .autoupdatingCurrent
    }
}

private struct OrphanReport: Equatable {
    let orphans: [MeasureCategory]

    static func == (lhs: OrphanReport, rhs: OrphanReport) -> Bool {
        lhs.orphans.map(\.persistentModelID) == rhs.orphans.map(\.persistentModelID)
    }

    var message: String {
        let names = orphans.prefix(5).map { entry in
            "\(entry.name) (was #\(entry.gsCategoryID.map(String.init) ?? "?"))"
        }
        var msg = names.joined(separator: "\n")
        if orphans.count > 5 {
            msg += "\n… and \(orphans.count - 5) more"
        }
        msg += "\n\nTheir Grand Shooting link will be cleared. You can re-link them from the category edit screen."
        return msg
    }
}
