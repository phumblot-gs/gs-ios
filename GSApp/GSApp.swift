import SwiftUI
import GSAPIClient
import GSCore

@main
struct GSApp: App {
    @State private var authState = AuthState()
    @State private var settings = DevSettings.shared
    @State private var catalog = CatalogCache.shared
    private let logger = GSLogger(category: "App")

    init() {
        logger.info("GS Mobile launching")
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if authState.isSignedIn {
                    RootView(authState: authState, settings: settings, catalog: catalog)
                } else {
                    LoginView(authState: authState, settings: settings)
                }
            }
            // Refresh the catalog (zones, categories, batch types) any time
            // we become signed in (cold launch with a persisted session, or
            // a fresh login). The view stays interactive while the refresh
            // runs in the background.
            .task(id: authState.isSignedIn) {
                if authState.isSignedIn {
                    await catalog.refresh(environment: settings.currentEnvironment)
                }
            }
            .onOpenURL { url in
                // Deep-link callback from `ASWebAuthenticationSession` /
                // backend OAuth flow: `gsmobile://auth/done?session_id=...`
                AuthDeepLinkHandler.handle(url)
            }
        }
    }
}

struct RootView: View {
    let authState: AuthState
    @Bindable var settings: DevSettings
    @Bindable var catalog: CatalogCache

    var body: some View {
        TabView {
            ScanTab(settings: settings)
                .tabItem { Label("Scan", systemImage: "barcode.viewfinder") }
            PhotoTab()
                .tabItem { Label("Photo", systemImage: "camera") }
            LiDARTab()
                .tabItem { Label("LiDAR", systemImage: "cube.transparent") }
            HistoryTab()
                .tabItem { Label("History", systemImage: "clock") }
            SettingsTab(authState: authState, settings: settings, catalog: catalog)
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .overlay(alignment: .top) {
            BackendStatusBanner(
                environment: settings.currentEnvironment,
                environmentName: settings.backendEnvironment.rawValue
            )
            .padding(.top, 4)
        }
    }
}
