import SwiftUI
import GSAPIClient
import GSCore

/// Detail screen for a `Reference`. Shows the reference identity, its
/// stock items (with status picker), and the view_types vs pictures
/// match. Used as the destination of both "Scan products" and the
/// upcoming batch / register flows.
struct ReferenceDetailView: View {
    let settings: DevSettings

    enum Source: Hashable {
        /// Result of a barcode scan — one or more `ReferenceStock` rows.
        case scan(ScanState.MatchedReference)
        /// Direct entry (used by the batch detail screen, etc.).
        case stock([ReferenceStock])
    }

    let source: Source

    // References live in State so the screen can reflect local mutations
    // (e.g. after a stock-item status update) without a re-fetch. Hydrated
    // from `source` on first appear via `.task(id:)`.
    @State private var references: [ReferenceStock] = []
    @State private var selectedIndex: Int = 0
    @State private var selectedStockItemIndex: Int = 0
    @State private var pictures: [Picture] = []
    @State private var statusSheetVisible = false
    @State private var statusUpdating = false
    @State private var showMeasureFlow = false
    @State private var showTechViewsCapture = false
    /// Inline error surfaced by a user-triggered action that
    /// failed (currently only the status change). Different
    /// channel from the on-load status banners so we don't
    /// conflate "this PATCH failed" with "the GET on appear
    /// failed".
    @State private var actionErrorMessage: String?

    /// Shared shape for both async loaders on this screen
    /// (`/stock` and `/picture`). `.loaded` covers both "data
    /// present" and "data legitimately empty" — the banner is
    /// only shown on `.failed` or `.refreshing`.
    enum LoadStatus: Equatable {
        case loaded
        case failed
        case refreshing
    }
    @State private var stockLoadStatus: LoadStatus = .loaded
    @State private var stockRetryTask: Task<Void, Never>?
    @State private var picturesLoadStatus: LoadStatus = .loaded
    @State private var picturesRetryTask: Task<Void, Never>?

    /// Returns the scan context (payload + attribute) when the
    /// detail view was opened from a barcode scan. Nil for direct
    /// entries (batch navigation, …) — those don't need to refetch
    /// `/stock` because the data was already validated upstream.
    private var scanContext: (payload: String, attribute: StockService.SearchAttribute)? {
        if case .scan(let match) = source {
            return (match.payload, match.searchAttribute)
        }
        return nil
    }

    private var sourceReferences: [ReferenceStock] {
        switch source {
        case .scan(let match): return match.references
        case .stock(let refs): return refs
        }
    }

    private var currentReferenceStock: ReferenceStock? {
        references.indices.contains(selectedIndex) ? references[selectedIndex] : nil
    }

    private var stockItems: [StockItem] {
        currentReferenceStock?.stockItems ?? []
    }

    private var currentStockItem: StockItem? {
        stockItems.indices.contains(selectedStockItemIndex) ? stockItems[selectedStockItemIndex] : nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                referenceCard
                if references.count > 1 {
                    referencePicker
                }
                if stockLoadStatus != .loaded {
                    stockLookupBanner
                }
                if !stockItems.isEmpty {
                    stockItemSection
                }
                measuresSection
                techViewsSection
                shotListSection
            }
            .padding()
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(.systemGroupedBackground))
        .refreshable {
            async let stock: Void = refreshStock(triggeredByUser: true)
            async let pics: Void = loadPictures(triggeredByUser: true)
            _ = await (stock, pics)
        }
        .task {
            if references.isEmpty { references = sourceReferences }
            await loadPictures(triggeredByUser: false)
            // If the upstream /stock GET failed during the scan,
            // surface the banner and schedule one auto-retry after
            // 5 s. The retry is cancellable — pull-to-refresh while
            // it's pending replaces it with the user-initiated one.
            if case .scan(let match) = source, match.stockLookupFailed {
                stockLoadStatus = .failed
                scheduleStockAutoRetry()
            }
        }
        .onDisappear {
            stockRetryTask?.cancel()
            picturesRetryTask?.cancel()
        }
        .alert(
            "Status update failed",
            isPresented: Binding(
                get: { actionErrorMessage != nil },
                set: { if !$0 { actionErrorMessage = nil } }
            ),
            actions: { Button("OK") { actionErrorMessage = nil } },
            message: { Text(actionErrorMessage ?? "") }
        )
        .sheet(isPresented: $statusSheetVisible) {
            statusPicker
        }
        .fullScreenCover(isPresented: $showMeasureFlow) {
            if let reference = currentReferenceStock?.reference {
                MeasureFlowView(settings: settings, attachedTo: reference) {
                    showMeasureFlow = false
                    Task { await refreshReferenceAfterMeasures() }
                }
            }
        }
        .fullScreenCover(isPresented: $showTechViewsCapture) {
            if let reference = currentReferenceStock?.reference {
                TechViewsCaptureView(
                    settings: settings,
                    reference: reference,
                    onExit: {
                        showTechViewsCapture = false
                        // The capture flow pushed fresh
                        // `extra.tech_views` to GS — pull the
                        // reference back so the section reflects
                        // what was just saved.
                        Task { await refreshReferenceAfterMeasures() }
                    }
                )
            }
        }
    }

    // MARK: - Reference identity

    private var referenceCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let display = currentReferenceStock?.reference.displayName {
                Text(display).font(.title3.bold())
            }
            HStack(spacing: 8) {
                Label(currentReferenceStock?.reference.ref ?? "—", systemImage: "barcode")
                    .font(.subheadline.monospaced())
                if let ean = currentReferenceStock?.reference.ean {
                    Text("· EAN \(ean)")
                        .font(.subheadline.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            categoryBreadcrumb
            HStack(spacing: 12) {
                if let count = picturesLatest.count as Int?, count > 0 {
                    Label("\(count) pictures", systemImage: "photo.stack")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let category = categoryForCurrent {
                    Label("\(category.viewTypes.count) views expected", systemImage: "rectangle.grid.2x2")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var categoryBreadcrumb: some View {
        let parts = [
            currentReferenceStock?.reference.univers,
            currentReferenceStock?.reference.gamme,
            currentReferenceStock?.reference.family
        ].compactMap { $0 }
        if !parts.isEmpty {
            Text(parts.joined(separator: " · "))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var categoryForCurrent: GSAPIClient.Category? {
        guard let id = currentReferenceStock?.reference.categoryID else { return nil }
        return CatalogCache.shared.category(id: id)
    }

    // MARK: - Multi-reference picker

    private var referencePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Match")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Picker("Match", selection: $selectedIndex) {
                ForEach(Array(references.enumerated()), id: \.offset) { index, ref in
                    Text(ref.reference.displayName).tag(index)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: - Stock item picker + status

    private var stockItemSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Stock items (\(stockItems.count))")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            if stockItems.count > 1 {
                Picker("Stock item", selection: $selectedStockItemIndex) {
                    ForEach(Array(stockItems.enumerated()), id: \.offset) { index, item in
                        Text("#\(item.id) · \(item.status.displayName)").tag(index)
                    }
                }
                .pickerStyle(.menu)
            }

            if let item = currentStockItem {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("Status", systemImage: "circle.fill")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(item.status.displayName)
                            .font(.headline)
                    }
                    if let ean = item.ean {
                        HStack {
                            Label("EAN", systemImage: "barcode")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(ean).font(.subheadline.monospaced())
                        }
                    }
                    Button {
                        statusSheetVisible = true
                    } label: {
                        if statusUpdating {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text("Updating…")
                            }
                            .frame(maxWidth: .infinity)
                        } else {
                            Label("Change status", systemImage: "arrow.right.circle")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(statusUpdating)
                }
                .padding()
                .background(.background, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var statusPicker: some View {
        NavigationStack {
            List {
                ForEach(StockItemStatus.orderedCases, id: \.rawValue) { status in
                    if settings.enabledStockItemStatuses.contains(status.rawValue) {
                        Button {
                            Task { await updateStatus(to: status) }
                        } label: {
                            HStack {
                                Text(status.displayName)
                                Spacer()
                                if currentStockItem?.status == status {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }
            .navigationTitle("Change status")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { statusSheetVisible = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Measurements

    private var measuresSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Measurements")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            VStack(alignment: .leading, spacing: 10) {
                let measures = currentReferenceStock?.reference.extra?.measures ?? [:]
                if measures.isEmpty {
                    Label("No measurements yet", systemImage: "ruler")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(measures.keys.sorted(), id: \.self) { name in
                        if let value = measures[name] {
                            HStack {
                                Text(name)
                                Spacer()
                                Text(formatted(value))
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Button {
                    showMeasureFlow = true
                } label: {
                    Label(
                        measures.isEmpty ? "Take measurements" : "Retake measurements",
                        systemImage: measures.isEmpty ? "ruler" : "arrow.counterclockwise"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(!GSDeviceSupport.hasLiDAR)
                if !GSDeviceSupport.hasLiDAR {
                    Text("Measurements need a LiDAR device.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding()
            .background(.background, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func formatted(_ value: ReferenceExtra.MeasureValue) -> String {
        String(format: "%.1f %@", value.value, value.unit)
    }

    // MARK: - Tech views

    /// Mirrors the categories in `TechViewCategory` against the
    /// `extra.tech_views` blob on the reference. Only categories
    /// with a non-empty value get a row.
    private var techViewEntries: [(category: TechViewCategory, value: String)] {
        guard let tv = currentReferenceStock?.reference.extra?.techViews else { return [] }
        let pairs: [(TechViewCategory, String?)] = [
            (.provenance,   tv.provenance),
            (.composition,  tv.composition),
            (.care,         tv.care),
            (.standards,    tv.standards),
            (.restrictions, tv.restrictions),
            (.notes,        tv.notes)
        ]
        return pairs.compactMap { category, raw in
            guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return nil }
            return (category, value)
        }
    }

    private var hasShootingMethod: Bool {
        settings.techViewsShootingMethodID != nil
    }

    private var techViewsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Tech views")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            VStack(alignment: .leading, spacing: 12) {
                let entries = techViewEntries
                if entries.isEmpty {
                    Label("No tech views yet", systemImage: "doc.text.viewfinder")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(entries, id: \.category) { entry in
                        techViewRow(entry.category, value: entry.value)
                    }
                }
                Button {
                    showTechViewsCapture = true
                } label: {
                    Label(
                        entries.isEmpty ? "Capture tech views" : "Add more tech views",
                        systemImage: entries.isEmpty ? "camera.viewfinder" : "plus"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(!hasShootingMethod)
                if !hasShootingMethod {
                    Text("Configure a shooting method in Settings → Grand Shooting before capturing tech views.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding()
            .background(.background, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func techViewRow(_ category: TechViewCategory, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(category.displayName, systemImage: category.symbolName)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @MainActor
    private func refreshReferenceAfterMeasures() async {
        guard let ref = currentReferenceStock?.reference.ref else { return }
        let service = ReferenceLookupService(environment: settings.currentEnvironment)
        do {
            let refreshed = try await service.lookup(scannedValue: ref, by: .ref)
            guard let updated = refreshed.first(where: { $0.ref == ref }) else { return }
            if references.indices.contains(selectedIndex) {
                let stock = references[selectedIndex]
                references[selectedIndex] = ReferenceStock(reference: updated, stockItems: stock.stockItems)
            }
        } catch {
            // Non-fatal: the measurements were saved server-side, the
            // user just won't see the refreshed list until they pop
            // back and revisit.
        }
    }

    // MARK: - Shot list

    private var shotListSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pictures")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            if picturesLoadStatus != .loaded {
                picturesLookupBanner
            }
            if picturesLoadStatus == .loaded {
                ForEach(shotListRows, id: \.id) { row in
                    ShotListRow(row: row)
                }
            }
        }
    }

    private var picturesLatest: [Picture] {
        pictures.latestByFilePath()
    }

    /// Build a row per view_type (in `rang` order) + extra picture rows
    /// for pictures whose view_type_code doesn't match any expected one.
    private var shotListRows: [ShotListRow.Row] {
        let cat = categoryForCurrent
        let expected = cat?.viewTypesByRang ?? []
        let latest = picturesLatest

        var rows: [ShotListRow.Row] = []
        var consumedPicturePayloads: Set<String> = []

        for vt in expected {
            let match = latest.first(where: { $0.viewTypeCode == vt.code })
            if let match {
                consumedPicturePayloads.insert(match.filePath ?? "picture_id:\(match.id)")
            }
            rows.append(.init(
                id: "vt-\(vt.code)",
                code: vt.code,
                title: vt.displayLabel,
                rang: vt.rang,
                picture: match
            ))
        }

        // Extra pictures (view_type_code not in expected list)
        let extras = latest.filter { picture in
            let key = picture.filePath ?? "picture_id:\(picture.id)"
            return !consumedPicturePayloads.contains(key)
        }
        for picture in extras {
            rows.append(.init(
                id: "extra-\(picture.id)",
                code: picture.viewTypeCode ?? "(extra)",
                title: picture.viewTypeCode.map { String(localized: "Extra view (\($0))") } ?? String(localized: "Extra picture"),
                rang: nil,
                picture: picture
            ))
        }

        return rows
    }

    // MARK: - API

    /// Mirrors `refreshStock(triggeredByUser:)`. On the initial
    /// load (`triggeredByUser == false`) a failure schedules one
    /// auto-retry 5 s later. On a manual refresh (pull-to-refresh
    /// or banner button) we cancel any pending auto-retry first
    /// so the two requests don't race.
    @MainActor
    private func loadPictures(triggeredByUser: Bool) async {
        guard let ref = currentReferenceStock?.reference.ref else { return }
        if triggeredByUser { picturesRetryTask?.cancel() }
        picturesLoadStatus = .refreshing
        do {
            let service = PictureService(environment: settings.currentEnvironment)
            pictures = try await service.list(forRef: ref)
            picturesLoadStatus = .loaded
        } catch {
            picturesLoadStatus = .failed
            if !triggeredByUser {
                schedulePicturesAutoRetry()
            }
        }
    }

    private func schedulePicturesAutoRetry() {
        picturesRetryTask?.cancel()
        picturesRetryTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            if Task.isCancelled { return }
            guard picturesLoadStatus == .failed else { return }
            await loadPictures(triggeredByUser: false)
        }
    }

    @MainActor
    private func updateStatus(to newStatus: StockItemStatus) async {
        guard let item = currentStockItem else { return }
        statusSheetVisible = false
        statusUpdating = true
        defer { statusUpdating = false }
        do {
            let service = StockService(environment: settings.currentEnvironment)
            let updated = try await service.update(
                id: item.id,
                payload: .init(status: newStatus)
            )
            // Splice the updated stock item back into `references` so the
            // displayed status changes immediately, without a re-fetch.
            if references.indices.contains(selectedIndex) {
                var refStock = references[selectedIndex]
                if let stockIndex = refStock.stockItems.firstIndex(where: { $0.id == updated.id }) {
                    var items = refStock.stockItems
                    items[stockIndex] = updated
                    refStock = ReferenceStock(reference: refStock.reference, stockItems: items)
                    references[selectedIndex] = refStock
                }
            }
        } catch let err as GSHTTPClient.HTTPError {
            actionErrorMessage = err.userMessage
        } catch {
            actionErrorMessage = error.localizedDescription
        }
    }

    // MARK: - Retry banners

    private var stockLookupBanner: some View {
        retryBanner(
            status: stockLoadStatus,
            failedTitle: "Couldn't load stock items.",
            refreshingTitle: "Reloading stock items…",
            retry: { Task { await refreshStock(triggeredByUser: true) } }
        )
    }

    private var picturesLookupBanner: some View {
        retryBanner(
            status: picturesLoadStatus,
            failedTitle: "Couldn't load pictures.",
            refreshingTitle: "Reloading pictures…",
            retry: { Task { await loadPictures(triggeredByUser: true) } }
        )
    }

    @ViewBuilder
    private func retryBanner(
        status: LoadStatus,
        failedTitle: LocalizedStringKey,
        refreshingTitle: LocalizedStringKey,
        retry: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            if status == .refreshing {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.title3)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(status == .refreshing ? refreshingTitle : failedTitle)
                    .font(.subheadline.weight(.semibold))
                if status == .failed {
                    Text("Pull to refresh, or tap Retry.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if status == .failed {
                Button("Retry", action: retry)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.orange.opacity(0.4), lineWidth: 1)
        )
    }

    /// Queues a single auto-retry of the `/stock` lookup 5 s after
    /// the banner appears. Cancellable via `stockRetryTask` so a
    /// manual pull-to-refresh or a navigation-away doesn't leave
    /// it firing in the background.
    private func scheduleStockAutoRetry() {
        stockRetryTask?.cancel()
        stockRetryTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            if Task.isCancelled { return }
            guard stockLoadStatus == .failed else { return }
            await refreshStock(triggeredByUser: false)
        }
    }

    /// Re-runs `StockService.search` for the scan payload, merges
    /// the result into the local `references` state, and updates
    /// `stockLoadStatus` so the banner reflects the outcome.
    /// `triggeredByUser == true` cancels any pending auto-retry.
    @MainActor
    private func refreshStock(triggeredByUser: Bool) async {
        guard let context = scanContext else { return }
        if triggeredByUser { stockRetryTask?.cancel() }
        stockLoadStatus = .refreshing
        let service = StockService(environment: settings.currentEnvironment)
        do {
            let matches = try await service.search(
                scannedValue: context.payload,
                by: context.attribute
            )
            references = references.map { existing in
                let items = matches.first(where: { $0.reference.ref == existing.reference.ref })?.stockItems ?? []
                return ReferenceStock(reference: existing.reference, stockItems: items)
            }
            // If the retry returned no items either, the call
            // technically succeeded — there genuinely is no stock
            // for this reference. Mark as loaded so the banner
            // disappears.
            stockLoadStatus = .loaded
        } catch {
            // Stay in `.failed` so the banner sticks. We never
            // re-schedule another auto-retry from here — that
            // would loop indefinitely on a flaky network. The
            // user retries via the banner button or
            // pull-to-refresh.
            stockLoadStatus = .failed
        }
    }
}

// MARK: - Shot list row

private struct ShotListRow: View {
    struct Row: Identifiable, Hashable {
        let id: String
        let code: String
        let title: String
        let rang: Int?
        let picture: Picture?
    }

    let row: Row

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(row.title)
                        .font(.subheadline.weight(.medium))
                    if let r = row.rang {
                        Text("#\(r)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Text(row.code)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                if row.picture == nil {
                    Label("Missing", systemImage: "exclamationmark.circle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
        }
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let url = row.picture?.thumbnailURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .empty:
                    ProgressView().controlSize(.small)
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                case .failure:
                    Image(systemName: "photo.badge.exclamationmark")
                        .foregroundStyle(.secondary)
                @unknown default:
                    EmptyView()
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary)
                .frame(width: 56, height: 56)
                .overlay {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
        }
    }
}
