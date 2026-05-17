import SwiftUI
import GSAPIClient

struct HistoryTab: View {
    let authState: AuthState

    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "No history yet",
                systemImage: "clock",
                description: Text("Recent scans, photos, and shipments will appear here.")
            )
            .navigationTitle("History")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Sign out", role: .destructive) {
                        Task { await authState.signOut() }
                    }
                }
            }
        }
    }
}
