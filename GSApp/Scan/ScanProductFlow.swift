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
    @State private var showManualEntry = false
    @State private var manualValue = ""

    var body: some View {
        NavigationStack(path: $navigation) {
            ZStack(alignment: .bottom) {
                LiveBarcodeScannerView(resetDelaySeconds: 0.5, minScanInterval: settings.scannerCooldownSeconds) { code in
                    Task { await handle(payload: code.payload, attributes: [settings.searchAttribute]) }
                }
                .ignoresSafeArea(edges: [.top, .leading, .trailing])

                banner
                    .padding(.horizontal)
                    .padding(.bottom, 24)
                    .animation(.spring(duration: 0.25), value: stateID)
            }
            .navigationTitle("Scan products")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showManualEntry = true
                    } label: {
                        Image(systemName: "keyboard")
                    }
                    .accessibilityLabel("Enter ref or EAN")
                }
            }
            .manualLookupAlert(isPresented: $showManualEntry, value: $manualValue) { typed in
                Task { await handle(payload: typed, attributes: manualAttributes) }
            }
            .navigationDestination(for: ScanState.MatchedReference.self) { match in
                ReferenceDetailView(settings: settings, source: .scan(match))
            }
        }
    }

    /// Lookup order for manual entry: the configured attribute first,
    /// then the other one — so a typed ref resolves even when the app
    /// is set to scan EANs (and vice-versa).
    private var manualAttributes: [StockService.SearchAttribute] {
        var attrs = [settings.searchAttribute]
        for attr in [StockService.SearchAttribute.ean, .ref] where !attrs.contains(attr) {
            attrs.append(attr)
        }
        return attrs
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
    private func handle(payload: String, attributes: [StockService.SearchAttribute]) async {
        let payload = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty else { return }
        feedback.didDetectCode()
        inflight = true
        lastScan = .lookingUp(payload)

        let environment = settings.currentEnvironment
        let referenceService = ReferenceLookupService(environment: environment)
        let stockService = StockService(environment: environment)

        do {
            // Primary: catalog lookup — the GS endpoint that always returns
            // the reference if it exists, even without stock items. Try
            // each requested attribute in order, keeping the one that hits.
            var references: [Reference] = []
            var matchedAttribute = attributes.first ?? settings.searchAttribute
            for attribute in attributes {
                let found = try await referenceService.lookup(scannedValue: payload, by: attribute)
                if !found.isEmpty {
                    references = found
                    matchedAttribute = attribute
                    break
                }
            }
            inflight = false
            guard !references.isEmpty else {
                feedback.didFailLookup(reason: .notFound)
                lastScan = .noMatch(payload)
                return
            }

            // Enrichment: fetch stock items if any exist. Failure here
            // doesn't fail the whole scan — we still show the reference,
            // just without a Stock items section. We DO surface the
            // failure to the detail view via `stockLookupFailed` so the
            // user gets a "couldn't load stock" banner and an auto-retry
            // (instead of silently believing the reference has no stock).
            var stockMatches: [ReferenceStock] = []
            var stockLookupFailed = false
            do {
                stockMatches = try await stockService.search(
                    scannedValue: payload,
                    by: matchedAttribute
                )
            } catch {
                stockLookupFailed = true
            }

            // Pair each (richer) /reference row with the stock items from
            // /stock. We deliberately keep the /reference variant — /stock
            // often returns a thinner Reference that's missing fields like
            // `category_id` and the shot list ends up blank.
            let combined: [ReferenceStock] = references.map { reference in
                let items = stockMatches
                    .first(where: { $0.reference.ref == reference.ref })?
                    .stockItems ?? []
                return ReferenceStock(reference: reference, stockItems: items)
            }
            feedback.didFindReference()
            lastScan = .matched(ScanState.MatchedReference(
                payload: payload,
                searchAttribute: matchedAttribute,
                references: combined,
                stockLookupFailed: stockLookupFailed
            ))
        } catch GSHTTPClient.HTTPError.notAuthenticated {
            inflight = false
            feedback.didFailLookup(reason: .other)
            lastScan = .notAuthenticated(payload)
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
        /// The raw barcode payload — used by the detail view to
        /// retry the `/stock` lookup if the original call failed.
        let payload: String
        /// Which `Reference` attribute was used as the lookup key.
        /// Propagated to the detail view for the same retry path.
        let searchAttribute: StockService.SearchAttribute
        let references: [ReferenceStock]
        /// True when the initial `/stock` GET failed. Tells the
        /// detail view to surface a "couldn't load stock items"
        /// banner and schedule an auto-retry.
        let stockLookupFailed: Bool
    }
}

// MARK: - Banner — see `BannerCard.swift` (shared with RegisterProductFlow).
