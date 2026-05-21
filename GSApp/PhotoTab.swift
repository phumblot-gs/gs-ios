import SwiftUI
import GSAPIClient

struct PhotoTab: View {
    @Bindable var settings: DevSettings

    var body: some View {
        NavigationStack {
            Group {
                if settings.techViewsShootingMethodID == nil {
                    notConfiguredView
                } else {
                    TechViewsFlow(settings: settings)
                }
            }
            .navigationTitle("Photo")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var notConfiguredView: some View {
        ContentUnavailableView {
            Label("Shooting method not set", systemImage: "camera.aperture")
        } description: {
            Text("Pick a shooting method in Settings → Technical views to enable technical-view uploads.")
        }
    }
}
