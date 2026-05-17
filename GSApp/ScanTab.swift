import SwiftUI
import GSScanner
import GSAPIClient
import GSCore

struct ScanTab: View {
    @State private var lastResult: ScanResultUI?
    @State private var inflight = false
    @State private var feedback = ScannerFeedback()
    private let service = ReferenceService(environment: .placeholder)

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                LiveBarcodeScannerView(cooldownSeconds: 2.0) { code in
                    Task { await handle(code) }
                }
                .ignoresSafeArea(edges: [.top, .leading, .trailing])

                resultBanner
                    .padding(.horizontal)
                    .padding(.bottom, 24)
                    .animation(.spring(duration: 0.25), value: lastResult?.id)
            }
            .navigationTitle("Scan")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder
    private var resultBanner: some View {
        if let result = lastResult {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: result.systemImage)
                    Text(result.title)
                        .font(.headline)
                    Spacer()
                    if inflight {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                if let subtitle = result.subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(result.accent.opacity(0.6), lineWidth: 1)
            )
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    @MainActor
    private func handle(_ code: ScannedCode) async {
        // Immediate haptic so the user feels the detection even before the
        // API resolves. The success/error beep follows once we know.
        feedback.didDetectCode()
        inflight = true
        lastResult = ScanResultUI(
            id: UUID(),
            title: "Looking up \(code.payload)…",
            subtitle: code.symbology.displayName,
            systemImage: "magnifyingglass",
            accent: .gray
        )

        do {
            let refs = try await service.lookupByEAN(code.payload)
            inflight = false
            if let first = refs.first {
                feedback.didFindReference()
                lastResult = ScanResultUI(
                    id: UUID(),
                    title: first.ref,
                    subtitle: first.smalltext ?? "Reference matched",
                    systemImage: "checkmark.circle.fill",
                    accent: .green
                )
            } else {
                feedback.didFailLookup(reason: .notFound)
                lastResult = ScanResultUI(
                    id: UUID(),
                    title: "No reference for \(code.payload)",
                    subtitle: "EAN not found in catalog",
                    systemImage: "questionmark.circle.fill",
                    accent: .orange
                )
            }
        } catch ReferenceService.LookupError.transport(let underlying) {
            inflight = false
            feedback.didFailLookup(reason: .transport)
            lastResult = ScanResultUI(
                id: UUID(),
                title: "Network error",
                subtitle: underlying.localizedDescription,
                systemImage: "exclamationmark.triangle.fill",
                accent: .red
            )
        } catch {
            inflight = false
            feedback.didFailLookup(reason: .other)
            lastResult = ScanResultUI(
                id: UUID(),
                title: "Lookup failed",
                subtitle: error.localizedDescription,
                systemImage: "exclamationmark.triangle.fill",
                accent: .red
            )
        }
    }
}

private struct ScanResultUI: Identifiable, Equatable {
    let id: UUID
    let title: String
    let subtitle: String?
    let systemImage: String
    let accent: Color
}

private extension ScannedSymbology {
    var displayName: String {
        switch self {
        case .ean13: return "EAN-13"
        case .ean8: return "EAN-8"
        case .upcE: return "UPC-E"
        case .code128: return "Code 128"
        case .code39: return "Code 39"
        case .code93: return "Code 93"
        case .itf14: return "ITF-14"
        case .qr: return "QR"
        case .dataMatrix: return "Data Matrix"
        case .pdf417: return "PDF417"
        case .aztec: return "Aztec"
        case .other(let raw): return raw
        }
    }
}
