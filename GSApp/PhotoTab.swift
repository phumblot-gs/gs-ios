import SwiftUI
import GSCamera
import GSAPIClient

struct PhotoTab: View {
    @Bindable var settings: DevSettings

    var body: some View {
        NavigationStack {
            Group {
                if settings.techViewsShootingMethodID == nil {
                    notConfiguredView
                } else {
                    // Phase B will plug the actual capture-and-upload
                    // flow in here. Stub keeps the existing camera
                    // preview wired up so the tab isn't blank.
                    CameraView { _ in
                        // TODO: hand off CapturedPhoto to upload pipeline.
                    }
                }
            }
            .navigationTitle("Photo")
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
