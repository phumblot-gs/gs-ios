import SwiftUI
import GSAPIClient
import GSScanner
import GSCamera
import GSCore

/// Tech-views capture pipeline. Two states:
///  1. Scanner: live barcode scanner, looks up the reference on hit
///     and hands it off to the capture state.
///  2. Capturing: live camera + shutter; on shot → preview overlay
///     with Keep / Retake. Keep resizes to ≤ 1200 px, encodes JPEG
///     and uploads to today's production for the configured shooting
///     method.
struct TechViewsFlow: View {
    @Bindable var settings: DevSettings

    @State private var step: Step = .scanning
    @State private var lookupError: String?

    enum Step: Equatable {
        case scanning
        case capturing(Reference)
    }

    var body: some View {
        switch step {
        case .scanning:
            TechViewsScannerView(
                settings: settings,
                onResolved: { reference in
                    step = .capturing(reference)
                },
                onError: { message in
                    lookupError = message
                }
            )
            .alert("Lookup failed", isPresented: Binding(
                get: { lookupError != nil },
                set: { if !$0 { lookupError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(lookupError ?? "")
            }

        case .capturing(let reference):
            TechViewsCaptureView(
                settings: settings,
                reference: reference,
                onExit: { _ in
                    step = .scanning
                }
            )
        }
    }
}
