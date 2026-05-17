import SwiftUI
import GSCore

@main
struct GSApp: App {
    private let logger = GSLogger(category: "App")

    init() {
        logger.info("GS Mobile launching")
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .onOpenURL { url in
                    // Deep-link callback from `ASWebAuthenticationSession` /
                    // backend OAuth flow: `gsmobile://auth/done?session_id=...`
                    AuthDeepLinkHandler.handle(url)
                }
        }
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            ScanTab()
                .tabItem { Label("Scan", systemImage: "barcode.viewfinder") }
            PhotoTab()
                .tabItem { Label("Photo", systemImage: "camera") }
            LiDARTab()
                .tabItem { Label("LiDAR", systemImage: "cube.transparent") }
            HistoryTab()
                .tabItem { Label("History", systemImage: "clock") }
        }
    }
}
