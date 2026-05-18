import SwiftUI

struct HistoryTab: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "No history yet",
                systemImage: "clock",
                description: Text("Recent scans, photos, and shipments will appear here.")
            )
            .navigationTitle("History")
        }
    }
}
