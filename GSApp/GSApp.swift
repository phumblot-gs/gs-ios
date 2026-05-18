import SwiftUI
import GSAPIClient
import GSCore

@main
struct GSApp: App {
    @State private var authState = AuthState()
    @State private var settings = DevSettings.shared
    private let logger = GSLogger(category: "App")

    init() {
        logger.info("GS Mobile launching")
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if authState.isAuthenticated {
                    RootView(authState: authState, settings: settings)
                } else {
                    LoginView(authState: authState, settings: settings)
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

    var body: some View {
        TabView {
            ScanTab(settings: settings)
                .tabItem { Label("Scan", systemImage: "barcode.viewfinder") }
            PhotoTab()
                .tabItem { Label("Photo", systemImage: "camera") }
            LiDARTab()
                .tabItem { Label("LiDAR", systemImage: "cube.transparent") }
            HistoryTab(authState: authState)
                .tabItem { Label("History", systemImage: "clock") }
            SettingsTab(authState: authState, settings: settings)
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
