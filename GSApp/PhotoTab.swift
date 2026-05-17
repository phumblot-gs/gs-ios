import SwiftUI
import GSCamera

struct PhotoTab: View {
    var body: some View {
        NavigationStack {
            CameraView { _ in
                // TODO: hand off CapturedPhoto to upload pipeline.
            }
            .navigationTitle("Photo")
        }
    }
}
