import SwiftUI
import GSLiDAR

struct LiDARTab: View {
    var body: some View {
        NavigationStack {
            LiDARScanView { _ in
                // TODO: persist LiDARScanResult.
            }
            .navigationTitle("LiDAR")
        }
    }
}
