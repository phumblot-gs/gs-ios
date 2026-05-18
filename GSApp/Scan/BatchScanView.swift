import SwiftUI
import GSScanner
import GSAPIClient
import GSCore

/// Modal scanner that resolves a scanned barcode to a `Batch` via its
/// `code` attribute, dismissing as soon as a match is found.
struct BatchScanView: View {
    let settings: DevSettings
    let onFound: @MainActor (Batch) -> Void
    let onFailed: @MainActor (String) -> Void

    @State private var inflight = false
    @State private var lastScannedCode: String?
    @State private var statusMessage: String = String(localized: "Aim at a batch barcode")
    @State private var feedback = ScannerFeedback()

    var body: some View {
        ZStack(alignment: .bottom) {
            LiveBarcodeScannerView(resetDelaySeconds: 0.6) { code in
                Task { await handle(code) }
            }
            .ignoresSafeArea()

            VStack {
                Text(statusMessage)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.6), in: Capsule())
                    .padding(.bottom, 20)
                if inflight {
                    ProgressView().tint(.white)
                }
            }
            .padding(.bottom, 24)
        }
    }

    @MainActor
    private func handle(_ code: ScannedCode) async {
        guard !inflight, code.payload != lastScannedCode else { return }
        lastScannedCode = code.payload
        feedback.didDetectCode()
        inflight = true
        statusMessage = String(localized: "Looking up \(code.payload)…")

        let service = BatchService(environment: settings.currentEnvironment)
        do {
            if let batch = try await service.find(byCode: code.payload) {
                feedback.didFindReference()
                onFound(batch)
            } else {
                feedback.didFailLookup(reason: .notFound)
                statusMessage = String(localized: "No batch found for \(code.payload)")
                inflight = false
                // Allow re-scan on the same value after the reset delay.
                lastScannedCode = nil
            }
        } catch {
            feedback.didFailLookup(reason: .transport)
            onFailed(error.localizedDescription)
        }
    }
}
