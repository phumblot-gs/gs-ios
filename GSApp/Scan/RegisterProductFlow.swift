import SwiftUI
import GSAPIClient

/// Placeholder — full implementation lands in Phase 5.
struct RegisterProductFlow: View {
    let settings: DevSettings

    var body: some View {
        ContentUnavailableView {
            Label("Register products", systemImage: "plus.rectangle.on.rectangle")
        } description: {
            Text("Scan an item to add it to a batch in your stock — coming in the next iteration.")
        }
        .navigationTitle("Register products")
    }
}
