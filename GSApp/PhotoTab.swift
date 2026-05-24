import SwiftUI
import GSAPIClient

/// Standalone Photo tab. The tech-views capture flow now lives
/// on the reference detail screen (reachable via Scan or Search),
/// so this tab is intentionally a placeholder — kept around so a
/// future standalone photo feature has a home, but otherwise just
/// shows a "Coming soon" card.
struct PhotoTab: View {
    @Bindable var settings: DevSettings

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("Coming soon", systemImage: "camera")
            } description: {
                Text("Tech-view captures now live on the reference detail screen (Scanner tab).")
            }
            .navigationTitle("Photo")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
