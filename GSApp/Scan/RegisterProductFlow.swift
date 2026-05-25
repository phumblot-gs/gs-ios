import SwiftUI
import GSScanner
import GSAPIClient
import GSCore

/// Option 3: scan products and add them to a batch as new stock items.
///
/// Flow:
///   1. Pick (or create) the batch we're registering into. Required —
///      `batch_id` can't be null on `POST /stock`.
///   2. Camera comes live; each successful scan looks up the reference,
///      checks whether a stock item already exists, and either creates
///      a new stock item with the default status or surfaces an
///      "already in stock" dialog.
struct RegisterProductFlow: View {
    let settings: DevSettings

    @State private var activeBatch: Batch?
    @State private var showBatchPicker = false
    @State private var feedback = ScannerFeedback()
    @State private var lastResult: RegisterResult = .idle
    @State private var inflight = false
    @State private var existingPrompt: ExistingPrompt?
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

    // MARK: - Scanner

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
                resultBanner
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
            .animation(.spring(duration: 0.25), value: resultBannerKey)
        }
    }

    private var resultBannerKey: String {
        switch lastResult {
        case .idle: return "idle"
        case .lookingUp(let p): return "lookup-\(p)"
        case .created(let ref, _): return "created-\(ref.ref)"
        case .failed(let m): return "failed-\(m)"
        }
    }

    @ViewBuilder
    private var resultBanner: some View {
        switch lastResult {
        case .idle:
            EmptyView()
        case .lookingUp(let payload):
            HStack {
                ProgressView().controlSize(.small)
                Text("Registering \(payload)…")
                    .font(.subheadline)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(.thinMaterial, in: Capsule())
        case .created(let reference, let item):
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                VStack(alignment: .leading) {
                    Text(reference.displayName).font(.headline)
                    Text("Added · \(item.status.displayName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .padding()
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - Scan handling

    @MainActor
    private func handle(_ code: ScannedCode, batch: Batch) async {
        guard !inflight else { return }
        feedback.didDetectCode()
        inflight = true
        lastResult = .lookingUp(code.payload)
        defer { inflight = false }

        let refLookup = ReferenceLookupService(environment: settings.currentEnvironment)
        let stockService = StockService(environment: settings.currentEnvironment)

        let references: [Reference]
        do {
            references = try await refLookup.lookup(
                scannedValue: code.payload,
                by: settings.searchAttribute
            )
        } catch {
            lastResult = .failed(error.localizedDescription)
            feedback.didFailLookup(reason: .transport)
            return
        }

        guard let reference = references.first else {
            feedback.didFailLookup(reason: .notFound)
            lastResult = .idle
            notFoundPayload = code.payload
            return
        }

        // Check if there's already a stock_item for this ref. We call /stock
        // with the same search attribute and filter on this batch_id to
        // count existing rows.
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

        if existingCount > 0 {
            // Hold the user's hand: show alert, they choose to add a new
            // sample or skip. Audio cue = warning.
            feedback.didFailLookup(reason: .notFound)
            existingPrompt = ExistingPrompt(
                reference: reference,
                existingCount: existingCount,
                scannedEAN: settings.searchAttribute == .ean ? code.payload : reference.ean
            )
            lastResult = .idle
            return
        }

        await create(
            reference: reference,
            ean: settings.searchAttribute == .ean ? code.payload : reference.ean,
            batch: batch
        )
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
            lastResult = .failed("Reference \(reference.ref) is missing a reference_id, can't register.")
            return
        }
        let stockService = StockService(environment: settings.currentEnvironment)
        let status = StockItemStatus(rawValue: settings.defaultStockItemStatusOnRegister)
            ?? .addToStock

        do {
            let response = try await stockService.create(.init(
                referenceID: referenceID,
                batchID: resolvedBatch.id,
                status: status,
                ean: ean
            ))
            feedback.didFindReference()
            // The newly-created stock item is the most recent one of the
            // response. Fall back to a locally-built placeholder if the
            // response unexpectedly carries no items.
            let createdItem = response.stockItems.last ?? StockItem(
                id: 0,
                batchID: resolvedBatch.id,
                status: status,
                ean: ean
            )
            lastResult = .created(reference: reference, item: createdItem)
        } catch let err as GSHTTPClient.HTTPError {
            feedback.didFailLookup(reason: .other)
            lastResult = .failed(err.userMessage)
        } catch {
            feedback.didFailLookup(reason: .other)
            lastResult = .failed(error.localizedDescription)
        }
    }
}

// MARK: - Supporting types

private enum RegisterResult {
    case idle
    case lookingUp(String)
    case created(reference: Reference, item: StockItem)
    case failed(String)
}

private struct ExistingPrompt: Identifiable {
    let id = UUID()
    let reference: Reference
    let existingCount: Int
    let scannedEAN: String?
}

// MARK: - Batch picker sheet — see `BatchPickerSheet.swift`.
