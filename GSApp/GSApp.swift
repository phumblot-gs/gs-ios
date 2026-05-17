import SwiftUI
import GSAPIClient
import GSCore

@main
struct GSApp: App {
    @State private var authState = AuthState()
    private let logger = GSLogger(category: "App")

    init() {
        logger.info("GS Mobile launching")
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if authState.isAuthenticated {
                    RootView(authState: authState)
                } else {
                    LoginView(authState: authState)
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

    var body: some View {
        TabView {
            ScanTab()
                .tabItem { Label("Scan", systemImage: "barcode.viewfinder") }
            PhotoTab()
                .tabItem { Label("Photo", systemImage: "camera") }
            LiDARTab()
                .tabItem { Label("LiDAR", systemImage: "cube.transparent") }
            HistoryTab(authState: authState)
                .tabItem { Label("History", systemImage: "clock") }
        }
        .overlay(alignment: .top) {
            BackendStatusBanner(environment: .staging, environmentName: "staging")
                .padding(.top, 4)
        }
    }
}
