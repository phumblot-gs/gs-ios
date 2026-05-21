import SwiftUI
import GSScanner
import GSAPIClient
import GSCore

/// Barcode entry point for the tech-views flow. Wraps the existing
/// live scanner; on a successful scan, looks up the reference via
/// the same `ReferenceLookupService` the rest of the app uses, then
/// hands off to the capture step.
struct TechViewsScannerView: View {
    let settings: DevSettings
    let onResolved: @MainActor (Reference) -> Void
    let onError: @MainActor (String) -> Void

    @State private var manualValue: String = ""
    @State private var isLookingUp = false
    @State private var feedback = ScannerFeedback()

    var body: some View {
        ZStack(alignment: .bottom) {
            LiveBarcodeScannerView(resetDelaySeconds: 1.0) { code in
                Task { await resolve(value: code.payload) }
            }
            .ignoresSafeArea()

            VStack(spacing: 12) {
                if isLookingUp {
                    HStack {
                        ProgressView().tint(.white)
                        Text("Looking up…").foregroundStyle(.white)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.6), in: Capsule())
                }
                HStack {
                    TextField("Or enter ref / EAN manually", text: $manualValue)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button("Look up") {
                        Task { await resolve(value: manualValue) }
                    }
                    .disabled(manualValue.trimmingCharacters(in: .whitespaces).isEmpty || isLookingUp)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
        .navigationTitle("Scan reference")
        .navigationBarTitleDisplayMode(.inline)
    }

    @MainActor
    private func resolve(value: String) async {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !isLookingUp else { return }
        isLookingUp = true
        defer { isLookingUp = false }
        feedback.didDetectCode()

        let service = ReferenceLookupService(environment: settings.currentEnvironment)
        do {
            let refs = try await service.lookup(scannedValue: trimmed, by: settings.searchAttribute)
            if let first = refs.first {
                feedback.didFindReference()
                manualValue = ""
                onResolved(first)
            } else {
                feedback.didFailLookup(reason: .notFound)
                onError("No reference for \(trimmed).")
            }
        } catch let err as GSHTTPClient.HTTPError {
            feedback.didFailLookup(reason: .transport)
            onError(err.userMessage)
        } catch {
            feedback.didFailLookup(reason: .other)
            onError(error.localizedDescription)
        }
    }
}
