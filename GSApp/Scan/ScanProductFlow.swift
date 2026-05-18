import SwiftUI
import GSScanner
import GSAPIClient
import GSCore

/// Option 1: scan → look up via `searchAttribute` → present the reference
/// detail (with stock items + status edit) as a push.
struct ScanProductFlow: View {
    let settings: DevSettings

    @State private var lastScan: ScanState = .idle
    @State private var inflight = false
    @State private var feedback = ScannerFeedback()
    @State private var navigation = NavigationPath()

    var body: some View {
        NavigationStack(path: $navigation) {
            ZStack(alignment: .bottom) {
                LiveBarcodeScannerView(resetDelaySeconds: 0.5) { code in
                    Task { await handle(code) }
                }
                .ignoresSafeArea(edges: [.top, .leading, .trailing])

                banner
                    .padding(.horizontal)
                    .padding(.bottom, 24)
                    .animation(.spring(duration: 0.25), value: stateID)
            }
            .navigationTitle("Scan products")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: ScanState.MatchedReference.self) { match in
                ReferenceDetailView(settings: settings, source: .scan(match))
            }
        }
    }

    @ViewBuilder
    private var banner: some View {
        switch lastScan {
        case .idle:
            EmptyView()
        case .lookingUp(let payload):
            BannerCard(
                title: "Looking up \(payload)…",
                systemImage: "magnifyingglass",
                accent: .gray,
                showProgress: inflight
            )
        case .notAuthenticated(let payload):
            BannerCard(
                title: "Scanned \(payload)",
                subtitle: "Configure your API key in Settings to enable lookups.",
                systemImage: "key.slash",
                accent: .orange
            )
        case .noMatch(let payload):
            BannerCard(
                title: "No reference for \(payload)",
                subtitle: "EAN not found in catalog.",
                systemImage: "questionmark.circle.fill",
                accent: .orange
            )
        case .transportError(let message):
            BannerCard(
                title: "Network error",
                subtitle: message,
                systemImage: "exclamationmark.triangle.fill",
                accent: .red
            )
        case .matched(let match):
            Button {
                navigation.append(match)
            } label: {
                BannerCard(
                    title: match.references.first?.reference.displayName ?? "Reference matched",
                    subtitle: "Tap to view details",
                    systemImage: "checkmark.circle.fill",
                    accent: .green,
                    chevron: true
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var stateID: String {
        switch lastScan {
        case .idle: return "idle"
        case .lookingUp(let p): return "looking-\(p)"
        case .notAuthenticated(let p): return "noauth-\(p)"
        case .noMatch(let p): return "nomatch-\(p)"
        case .transportError(let m): return "transport-\(m)"
        case .matched(let m): return "matched-\(m.id)"
        }
    }

    // MARK: - Scan handling

    @MainActor
    private func handle(_ code: ScannedCode) async {
        feedback.didDetectCode()
        inflight = true
        lastScan = .lookingUp(code.payload)

        let environment = settings.currentEnvironment
        let referenceService = ReferenceLookupService(environment: environment)
        let stockService = StockService(environment: environment)

        do {
            // Primary: catalog lookup — the GS endpoint that always returns
            // the reference if it exists, even without stock items.
            let references = try await referenceService.lookup(
                scannedValue: code.payload,
                by: settings.searchAttribute
            )
            inflight = false
            guard !references.isEmpty else {
                feedback.didFailLookup(reason: .notFound)
                lastScan = .noMatch(code.payload)
                return
            }

            // Enrichment: fetch stock items if any exist. Failure here
            // doesn't fail the whole scan — we still show the reference,
            // just without a Stock items section.
            let stockMatches = (try? await stockService.search(
                scannedValue: code.payload,
                by: settings.searchAttribute
            )) ?? []

            // Pair each reference with its stock items (matched by `ref`),
            // falling back to "reference with empty stock_items" when the
            // /stock endpoint had nothing.
            let combined: [ReferenceStock] = references.map { reference in
                if let match = stockMatches.first(where: { $0.reference.ref == reference.ref }) {
                    return match
                }
                return ReferenceStock(reference: reference, stockItems: [])
            }
            feedback.didFindReference()
            lastScan = .matched(ScanState.MatchedReference(payload: code.payload, references: combined))
        } catch GSHTTPClient.HTTPError.notAuthenticated {
            inflight = false
            feedback.didFailLookup(reason: .other)
            lastScan = .notAuthenticated(code.payload)
        } catch GSHTTPClient.HTTPError.transport(let underlying) {
            inflight = false
            feedback.didFailLookup(reason: .transport)
            lastScan = .transportError(underlying.localizedDescription)
        } catch {
            inflight = false
            feedback.didFailLookup(reason: .other)
            lastScan = .transportError(error.localizedDescription)
        }
    }
}

// MARK: - Scan state

enum ScanState {
    case idle
    case lookingUp(String)
    case notAuthenticated(String)
    case noMatch(String)
    case transportError(String)
    case matched(MatchedReference)

    struct MatchedReference: Hashable, Identifiable {
        let id = UUID()
        let payload: String
        let references: [ReferenceStock]
    }
}

// MARK: - Banner

private struct BannerCard: View {
    let title: String
    var subtitle: String? = nil
    let systemImage: String
    let accent: Color
    var showProgress: Bool = false
    var chevron: Bool = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(accent)
                .font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .multilineTextAlignment(.leading)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
            }
            Spacer()
            if showProgress {
                ProgressView().controlSize(.small)
            } else if chevron {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(accent.opacity(0.4), lineWidth: 1)
        )
    }
}
