import SwiftUI
import GSScanner

struct ScanTab: View {
    @State private var lastScan: String = "—"

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("Last scan: \(lastScan)")
                    .font(.headline)
                    .padding()
                BarcodeScannerView { payload in
                    lastScan = payload
                }
            }
            .navigationTitle("Scan")
        }
    }
}
