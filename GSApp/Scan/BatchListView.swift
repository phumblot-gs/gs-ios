import SwiftUI
import GSAPIClient

/// Placeholder — full implementation lands in Phase 4.
struct BatchListView: View {
    let settings: DevSettings

    var body: some View {
        ContentUnavailableView {
            Label("Batches", systemImage: "shippingbox")
        } description: {
            Text("List, scan, edit and create batches — coming in the next iteration.")
        }
        .navigationTitle("Batches")
    }
}
