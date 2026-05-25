import SwiftUI
import GSScanner
import GSAPIClient
import GSCore

/// Scan products and add them to a batch as new stock items.
///
/// Flow:
///   1. Pick (or create) the batch we're registering into — `batch_id`
///      can't be null on `POST /stock`.
///   2. Camera comes live. Scanning a barcode looks up the catalog and
///      surfaces a reference card under the reticle, exactly like
///      `ScanProductFlow`. Tapping that card registers a new stock
///      item in the active batch.
///   3. If the reference already has stock items in the batch, an
///      "Already in stock" alert lets the user confirm a duplicate
///      or skip.
///   4. The success state persists below the reticle until the next
///      scan replaces it — visual confirmation that the registration
///      completed.
struct RegisterProductFlow: View {
    let settings: DevSettings

    @State private var activeBatch: Batch?
    @State private var showBatchPicker = false
    @State private var feedback = ScannerFeedback()
    @State private var lastScan: RegisterScanState = .idle
    @State private var inflight = false
    /// Set when tapping the matched card finds the reference already
    /// has stock items in the active batch. Drives the alert below.
    @State private var existingPrompt: ExistingPrompt?
    /// Last scanned EAN that didn't resolve to any catalog reference.
    /// Surfaced as an alert so the user gets a clear "not found".
    @State private var notFoundPayload: String?

    var body: some View {
        Group {
            if let batch = activeBatch {
                scannerView(for: batch)
            } else {
                emptyState
            }
        }
        .navigationTitle("Register products")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let batch = activeBatch {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showBatchPicker = true
                    } label: {
                        HStack(spacing: 4) {
                            Text(batch.displayName).lineLimit(1)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.footnote)
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showBatchPicker) {
            BatchPickerSheet(
                settings: settings,
                currentBatchID: activeBatch?.id
            ) { selected in
                activeBatch = selected
                showBatchPicker = false
            }
        }
        .alert(item: $existingPrompt) { prompt in
            Alert(
                title: Text("Already in stock"),
                message: Text("\(prompt.reference.displayName) already has \(prompt.existingCount) stock item(s) in this batch."),
                primaryButton: .default(Text("Add another")) {
                    Task { await create(reference: prompt.reference, ean: prompt.scannedEAN) }
                },
                secondaryButton: .cancel(Text("Skip"))
            )
        }
        .alert("EAN not in catalog", isPresented: Binding(
            get: { notFoundPayload != nil },
            set: { if !$0 { notFoundPayload = nil } }
        )) {
            Button("OK") { notFoundPayload = nil }
        } message: {
            Text(notFoundPayload.map { "No reference matches \($0)." } ?? "")
        }
    }

    // MARK: - Empty state (no batch chosen)

    private var emptyState: some View {
        VStack(spacing: 24) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.tint)
            Text("Choose a batch first")
                .font(.title3.bold())
            Text("Stock items are always linked to a batch. Pick the box, shelf or pallet you're registering into.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                showBatchPicker = true
            } label: {
                Label("Select a batch", systemImage: "shippingbox")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - Scanner + banner

    @ViewBuilder
    private func scannerView(for batch: Batch) -> some View {
        ZStack(alignment: .bottom) {
            LiveBarcodeScannerView(resetDelaySeconds: 0.6) { code in
                Task { await handle(code, batch: batch) }
            }
            .ignoresSafeArea(edges: [.top, .leading, .trailing])

            VStack(spacing: 12) {
                if !batch.displayName.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "shippingbox.fill")
                        Text("Registering to \(batch.displayName)")
                        if let zone = batch.zone, !zone.isEmpty {
                            Text("· \(zone)")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.thinMaterial, in: Capsule())
                }
                banner(for: batch)
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
            .animation(.spring(duration: 0.25), value: stateID)
        }
    }

    /// Banner under the reticle. Mirrors the visual language of
    /// `ScanProductFlow`: gray for in-flight lookups, green for a
    /// confirmed registration, red for network failure, and a
    /// tappable green-bordered card when a reference is awaiting
    /// confirmation.
    @ViewBuilder
    private func banner(for batch: Batch) -> some View {
        switch lastScan {
        case .idle:
            EmptyView()
        case .lookingUp(let payload):
            BannerCard(
                title: "Looking up \(payload)…",
                systemImage: "magnifyingglass",
                accent: .gray,
                showProgress: true
            )
        case .matched(let match):
            // Tap-to-register card — the central change vs the
            // previous flow. The reference is shown, the user
            // confirms by tapping.
            Button {
                Task { await confirmRegistration(of: match, batch: batch) }
            } label: {
                BannerCard(
                    title: match.reference.displayName,
                    subtitle: matchedSubtitle(for: match),
                    systemImage: "plus.circle.fill",
                    accent: .blue,
                    chevron: true
                )
            }
            .buttonStyle(.plain)
            .disabled(inflight)
        case .creating(let payload):
            BannerCard(
                title: "Registering \(payload)…",
                systemImage: "tray.and.arrow.down.fill",
                accent: .gray,
                showProgress: true
            )
        case .created(let reference, let item):
            BannerCard(
                title: reference.displayName,
                subtitle: String(localized: "Added · \(item.status.displayName)"),
                systemImage: "checkmark.circle.fill",
                accent: .green
            )
        case .transportError(let message):
            BannerCard(
                title: "Network error",
                subtitle: message,
                systemImage: "exclamationmark.triangle.fill",
                accent: .red
            )
        }
    }

    /// Helper text under the matched reference name. Indicates
    /// what would happen on tap (register), and warns when the
    /// reference is already stocked in this batch.
    private func matchedSubtitle(for match: MatchedForRegister) -> String {
        if match.existingCount > 0 {
            return String(localized: "Tap to add (already \(match.existingCount) in this batch)")
        }
        return String(localized: "Tap to add to this batch")
    }

    /// Stable identity per state — used by `.animation(_:value:)`
    /// so SwiftUI knows when to interpolate between banner shapes.
    private var stateID: String {
        switch lastScan {
        case .idle: return "idle"
        case .lookingUp(let p): return "lookup-\(p)"
        case .matched(let m): return "matched-\(m.reference.ref)"
        case .creating(let p): return "creating-\(p)"
        case .created(let r, _): return "created-\(r.ref)"
        case .transportError(let m): return "err-\(m)"
        }
    }

    // MARK: - Scan handling

    /// Step 1: a fresh code lands. Look up the catalog + count
    /// existing stock items in the active batch. Result drives the
    /// state into either `.matched(...)` (showing the card) or one
    /// of the error states / alerts.
    @MainActor
    private func handle(_ code: ScannedCode, batch: Batch) async {
        feedback.didDetectCode()
        inflight = true
        defer { inflight = false }
        lastScan = .lookingUp(code.payload)

        let refLookup = ReferenceLookupService(environment: settings.currentEnvironment)
        let stockService = StockService(environment: settings.currentEnvironment)

        let references: [Reference]
        do {
            references = try await refLookup.lookup(
                scannedValue: code.payload,
                by: settings.searchAttribute
            )
        } catch {
            feedback.didFailLookup(reason: .transport)
            lastScan = .transportError(error.localizedDescription)
            return
        }

        guard let reference = references.first else {
            feedback.didFailLookup(reason: .notFound)
            lastScan = .idle
            notFoundPayload = code.payload
            return
        }

        // Count existing items in this batch — used to decide
        // whether the "Already in stock" alert fires on tap.
        let existingCount: Int
        do {
            let matches = try await stockService.search(
                scannedValue: code.payload,
                by: settings.searchAttribute
            )
            existingCount = matches.flatMap(\.stockItems).filter { $0.batchID == batch.id }.count
        } catch {
            existingCount = 0
        }

        feedback.didFindReference()
        lastScan = .matched(MatchedForRegister(
            reference: reference,
            payload: code.payload,
            existingCount: existingCount
        ))
    }

    /// Step 2: user tapped the matched card. If there's already
    /// stock for this reference in the batch, surface the
    /// confirmation alert; otherwise create directly.
    @MainActor
    private func confirmRegistration(of match: MatchedForRegister, batch: Batch) async {
        let ean = settings.searchAttribute == .ean ? match.payload : match.reference.ean
        if match.existingCount > 0 {
            existingPrompt = ExistingPrompt(
                reference: match.reference,
                existingCount: match.existingCount,
                scannedEAN: ean
            )
            return
        }
        await create(reference: match.reference, ean: ean, batch: batch)
    }

    @MainActor
    private func create(
        reference: Reference,
        ean: String?,
        batch: Batch? = nil
    ) async {
        guard let resolvedBatch = batch ?? activeBatch else { return }
        // `reference_id` is required by GS — bail out clearly if the
        // lookup response didn't include one.
        guard let referenceID = reference.id else {
            feedback.didFailLookup(reason: .other)
            lastScan = .transportError(String(localized: "Reference \(reference.ref) is missing a reference_id, can't register."))
            return
        }
        let stockService = StockService(environment: settings.currentEnvironment)
        let status = StockItemStatus(rawValue: settings.defaultStockItemStatusOnRegister)
            ?? .addToStock

        inflight = true
        defer { inflight = false }
        lastScan = .creating(reference.ref)

        do {
            let response = try await stockService.create(.init(
                referenceID: referenceID,
                batchID: resolvedBatch.id,
                status: status,
                ean: ean
            ))
            feedback.didFindReference()
            // The newly-created stock item is the most recent one of
            // the response. Fall back to a locally-built placeholder
            // if the response unexpectedly carries no items.
            let createdItem = response.stockItems.last ?? StockItem(
                id: 0,
                batchID: resolvedBatch.id,
                status: status,
                ean: ean
            )
            lastScan = .created(reference: reference, item: createdItem)
        } catch let err as GSHTTPClient.HTTPError {
            feedback.didFailLookup(reason: .other)
            lastScan = .transportError(err.userMessage)
        } catch {
            feedback.didFailLookup(reason: .other)
            lastScan = .transportError(error.localizedDescription)
        }
    }
}

// MARK: - Supporting types

/// State machine for the scanner banner. The `.matched` arm is
/// the click-to-register surface — `.created` is the persistent
/// success state shown until the next scan.
private enum RegisterScanState {
    case idle
    case lookingUp(String)
    case matched(MatchedForRegister)
    case creating(String)
    case created(reference: Reference, item: StockItem)
    case transportError(String)
}

/// Snapshot of the scan + lookup, awaiting the user's tap to
/// confirm the registration. Carries the existing-count so the
/// banner subtitle can warn about duplicates before the alert.
private struct MatchedForRegister: Hashable {
    let reference: Reference
    let payload: String
    let existingCount: Int
}

private struct ExistingPrompt: Identifiable {
    let id = UUID()
    let reference: Reference
    let existingCount: Int
    let scannedEAN: String?
}

// MARK: - Batch picker sheet — see `BatchPickerSheet.swift`.
