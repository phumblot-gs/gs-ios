import SwiftUI
import GSScanner
import GSAPIClient
import GSCore

/// Bulk status-change flow launched from `BatchDetailView`. Two
/// steps:
///   1. The user picks a target status (sheet — `BulkStatusTargetPicker`).
///   2. A scanner screen (this view) reads barcodes one by one;
///      each scan is resolved against the **current batch's**
///      stock items. A matching stock item is presented in a
///      tappable card; tap → PATCH `/stock/<id>` to the target
///      status; the success banner auto-resets after 1.5 s so the
///      user can chain scans.
///
/// Edge cases visible to the user:
///   - Scanned product has no stock item in this batch → red
///     banner with an error sound, non-tappable.
///   - Stock item is already at the target status → grey banner
///     "Already at this status", non-tappable.
///   - Multiple stock items for the same reference in the batch
///     → blue banner that opens a chooser sheet listing every
///     stock item with its current status.
struct BatchBulkStatusFlow: View {
    let settings: DevSettings
    let batch: Batch
    let targetStatus: StockItemStatus

    @State private var lastScan: BulkScanState = .idle
    @State private var feedback = ScannerFeedback()
    /// Set when the scanned reference has multiple stock items
    /// in this batch — surfaces the chooser sheet.
    @State private var pendingPicker: BulkPickerData?
    /// Tracks an in-flight PATCH so we don't fire the same one
    /// twice on rapid taps.
    @State private var inflight = false
    /// Cancels the previous auto-reset task when a new scan
    /// arrives, otherwise a stale `.idle` would clobber the new
    /// banner mid-display.
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .bottom) {
            LiveBarcodeScannerView(resetDelaySeconds: 0.6) { code in
                Task { await handle(code) }
            }
            .ignoresSafeArea(edges: [.top, .leading, .trailing])

            VStack(spacing: 12) {
                headerCapsule
                banner
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
            .animation(.spring(duration: 0.25), value: stateID)
        }
        .navigationTitle("Bulk change status")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $pendingPicker) { data in
            BulkStockItemPicker(
                reference: data.reference,
                stockItems: data.stockItems,
                targetStatus: targetStatus
            ) { item in
                pendingPicker = nil
                Task { await apply(item: item, reference: data.reference) }
            }
        }
        .onDisappear { resetTask?.cancel() }
    }

    private var headerCapsule: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.right.circle.fill")
            Text("→ \(targetStatus.displayName)")
            Text("·")
                .foregroundStyle(.secondary)
            Text(batch.displayName)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: Capsule())
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
                showProgress: true
            )
        case .notInBatch(let payload):
            BannerCard(
                title: "Not in this batch",
                subtitle: "No stock item for \(payload) in \(batch.displayName).",
                systemImage: "xmark.circle.fill",
                accent: .red
            )
        case .sameStatus(let reference, _):
            BannerCard(
                title: reference.displayName,
                subtitle: "Already at \(targetStatus.displayName)",
                systemImage: "checkmark.circle",
                accent: .gray
            )
        case .matchedSingle(let reference, _):
            Button {
                if case .matchedSingle(let r, let i) = lastScan {
                    Task { await apply(item: i, reference: r) }
                }
            } label: {
                BannerCard(
                    title: reference.displayName,
                    subtitle: "Tap to set to \(targetStatus.displayName)",
                    systemImage: "arrow.right.circle.fill",
                    accent: .blue,
                    chevron: true
                )
            }
            .buttonStyle(.plain)
            .disabled(inflight)
        case .matchedMultiple(let reference, let items):
            Button {
                pendingPicker = BulkPickerData(reference: reference, stockItems: items)
            } label: {
                BannerCard(
                    title: reference.displayName,
                    subtitle: "\(items.count) stock items — tap to choose",
                    systemImage: "list.bullet.rectangle",
                    accent: .blue,
                    chevron: true
                )
            }
            .buttonStyle(.plain)
            .disabled(inflight)
        case .updating:
            BannerCard(
                title: "Updating…",
                systemImage: "arrow.triangle.2.circlepath",
                accent: .gray,
                showProgress: true
            )
        case .updated(let reference, let item):
            BannerCard(
                title: reference.displayName,
                subtitle: "Set to \(item.status.displayName)",
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

    private var stateID: String {
        switch lastScan {
        case .idle: return "idle"
        case .lookingUp(let p): return "look-\(p)"
        case .notInBatch(let p): return "not-\(p)"
        case .sameStatus(_, let i): return "same-\(i.id)"
        case .matchedSingle(_, let i): return "single-\(i.id)"
        case .matchedMultiple(let r, _): return "multi-\(r.ref)"
        case .updating: return "updating"
        case .updated(_, let i): return "updated-\(i.id)"
        case .transportError(let m): return "err-\(m)"
        }
    }

    // MARK: - Scan handling

    @MainActor
    private func handle(_ code: ScannedCode) async {
        resetTask?.cancel()
        feedback.didDetectCode()
        lastScan = .lookingUp(code.payload)

        let refLookup = ReferenceLookupService(environment: settings.currentEnvironment)
        let stockService = StockService(environment: settings.currentEnvironment)

        // Catalog lookup. A missing reference is treated the same
        // as "not in this batch" — both mean the user can't apply
        // the target status to anything.
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
            lastScan = .notInBatch(code.payload)
            return
        }

        // Filter the reference's stock items down to those in
        // this specific batch.
        let matchesInBatch: [StockItem]
        do {
            let all = try await stockService.search(
                scannedValue: code.payload,
                by: settings.searchAttribute
            )
            matchesInBatch = all
                .filter { $0.reference.ref == reference.ref }
                .flatMap(\.stockItems)
                .filter { $0.batchID == batch.id }
        } catch {
            feedback.didFailLookup(reason: .transport)
            lastScan = .transportError(error.localizedDescription)
            return
        }

        switch matchesInBatch.count {
        case 0:
            feedback.didFailLookup(reason: .notFound)
            lastScan = .notInBatch(code.payload)
        case 1:
            let item = matchesInBatch[0]
            feedback.didFindReference()
            if item.status == targetStatus {
                lastScan = .sameStatus(reference, item)
            } else {
                lastScan = .matchedSingle(reference, item)
            }
        default:
            feedback.didFindReference()
            lastScan = .matchedMultiple(reference, matchesInBatch)
        }
    }

    @MainActor
    private func apply(item: StockItem, reference: Reference) async {
        guard !inflight else { return }
        inflight = true
        defer { inflight = false }
        lastScan = .updating(reference.ref)

        let stockService = StockService(environment: settings.currentEnvironment)
        do {
            let updated = try await stockService.update(
                id: item.id,
                payload: .init(status: targetStatus)
            )
            feedback.didFindReference()
            lastScan = .updated(reference: reference, item: updated)
            // Auto-clear after 1.5 s so the operator can resume
            // scanning fluidly without a manual reset.
            resetTask?.cancel()
            resetTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(1500))
                if !Task.isCancelled, case .updated = lastScan {
                    lastScan = .idle
                }
            }
        } catch let err as GSHTTPClient.HTTPError {
            feedback.didFailLookup(reason: .other)
            lastScan = .transportError(err.userMessage)
        } catch {
            feedback.didFailLookup(reason: .other)
            lastScan = .transportError(error.localizedDescription)
        }
    }
}

// MARK: - Target status picker (step 1)

/// Modal sheet shown from `BatchDetailView` to pick the target
/// status before entering the scanner. Same shape as the
/// reference-detail status picker, minus the "next" shortcut.
struct BulkStatusTargetPicker: View {
    let settings: DevSettings
    let onPick: @MainActor (StockItemStatus) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(StockItemStatus.orderedCases, id: \.rawValue) { status in
                    if settings.enabledStockItemStatuses.contains(status.rawValue) {
                        Button {
                            onPick(status)
                        } label: {
                            Text(status.displayName)
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }
            .navigationTitle("Target status")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Multi-pick chooser (step 2.5)

/// Sheet shown when a scanned reference resolves to several
/// stock items in the same batch. Lists each one with its
/// current status so the user can pick which to update.
private struct BulkStockItemPicker: View {
    let reference: Reference
    let stockItems: [StockItem]
    let targetStatus: StockItemStatus
    let onSelect: @MainActor (StockItem) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(stockItems, id: \.id) { item in
                        Button {
                            onSelect(item)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Stock item #\(item.id)")
                                        .font(.subheadline.weight(.medium))
                                    Text(item.status.displayName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if item.status == targetStatus {
                                    Text("No change")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                } header: {
                    Text(reference.displayName)
                } footer: {
                    Text("Pick a stock item to set to \(targetStatus.displayName).")
                }
            }
            .navigationTitle("Pick a stock item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Supporting types

/// Identifiable wrapper around the multi-pick context so the
/// `.sheet(item:)` modifier can present it cleanly.
private struct BulkPickerData: Identifiable, Hashable {
    let id = UUID()
    let reference: Reference
    let stockItems: [StockItem]
}

/// State machine for the scanner banner. Mirrors the structure
/// of ScanProductFlow / RegisterProductFlow but with this flow's
/// specific terminal states (`.notInBatch`, `.sameStatus`).
private enum BulkScanState {
    case idle
    case lookingUp(String)
    case notInBatch(String)
    case sameStatus(Reference, StockItem)
    case matchedSingle(Reference, StockItem)
    case matchedMultiple(Reference, [StockItem])
    case updating(String)
    case updated(reference: Reference, item: StockItem)
    case transportError(String)
}
