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
    @State private var showMetadataEditor = false
    /// Per-category draft text used by the Metadata editor sheet,
    /// keyed by `TechViewCategory.rawValue`. Seeded from the
    /// reference's current values when the sheet opens.
    @State private var metadataDrafts: [String: String] = [:]
    @State private var metadataSaving = false
    @State private var metadataSaveError: String?

    @State private var techViewPictures: [Picture] = []
    @State private var techViewsLoadStatus: LoadStatus = .loaded
    @State private var techViewsRetryTask: Task<Void, Never>?

    /// JPEG bytes for pictures the user just uploaded via the
    /// capture flow, keyed by filename. Used as a render fallback
    /// while GS finishes generating the CDN thumbnail URL — once
    /// `picture.thumbnail` arrives on a subsequent `loadTechViews`,
    /// the CDN copy takes over. Survives for the lifetime of this
    /// screen; the cost (a handful of JPEGs in memory) is bounded
    /// by how many shots the user takes in one sitting.
    @State private var localCapturePreviews: [String: Data] = [:]

    /// Carousel currently presented full-screen. Built when the
    /// user taps a thumbnail — captures the whole bucket (Measures
    /// / Labels / Tech views) so the user can swipe between
    /// siblings. The `fullScreenCover` binding clears it to nil
    /// on dismiss.
    @State private var zoomPresentation: ZoomPresentation?
    /// Namespace shared by every thumbnail and the zoom destination
    /// so SwiftUI can run a matched-geometry zoom transition.
    @Namespace private var pictureZoomNamespace
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
                metadataSection
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
            async let tech: Void = loadTechViews(triggeredByUser: true)
            _ = await (stock, pics, tech)
        }
        .task {
            if references.isEmpty { references = sourceReferences }
            // Record the visit as soon as a reference is bound to
            // the screen — same hook for both scan and search
            // entry points. Re-visiting bumps the existing entry
            // back to the top of the history.
            if let ref = currentReferenceStock?.reference {
                ReferenceHistoryStore.shared.record(ref)
            }
            await loadPictures(triggeredByUser: false)
            await loadTechViews(triggeredByUser: false)
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
            techViewsRetryTask?.cancel()
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
                if settings.isMeasureEnabled {
                    MeasureFlowView(
                        settings: settings,
                        attachedTo: reference,
                        onDone: {
                            showMeasureFlow = false
                            // Same dual-refresh as the tech-views exit:
                            // the reference picks up `extra.measures`,
                            // the picture gallery picks up the just-
                            // uploaded illustration so it appears in
                            // the Measures section without a manual
                            // pull-to-refresh.
                            Task {
                                await refreshReferenceAfterMeasures()
                                await loadTechViews(triggeredByUser: true)
                            }
                        },
                        onIllustrationReady: { preview in
                            localCapturePreviews[preview.filename] = preview.jpegData
                        }
                    )
                } else {
                    // Measure feature toggled off — present a plain
                    // photo capture locked to the Measure mode so
                    // the user can still document the product under
                    // the Measurement filename pattern.
                    TechViewsCaptureView(
                        settings: settings,
                        reference: reference,
                        lockedMode: .measure,
                        onExit: { previews in
                            showMeasureFlow = false
                            for preview in previews {
                                localCapturePreviews[preview.filename] = preview.jpegData
                            }
                            Task { await loadTechViews(triggeredByUser: true) }
                        }
                    )
                }
            }
        }
        .fullScreenCover(isPresented: $showTechViewsCapture) {
            if let reference = currentReferenceStock?.reference {
                TechViewsCaptureView(
                    settings: settings,
                    reference: reference,
                    onExit: { previews in
                        showTechViewsCapture = false
                        // Keep just-uploaded JPEGs in memory keyed
                        // by filename so the gallery can render them
                        // until GS finishes generating CDN
                        // thumbnails (otherwise the latest shot
                        // shows as an empty slot for ~30s).
                        for preview in previews {
                            localCapturePreviews[preview.filename] = preview.jpegData
                        }
                        // The capture flow pushed fresh
                        // `extra.tech_views` to GS AND uploaded
                        // new tech-view pictures — refresh both
                        // the reference (for the Metadata block)
                        // and the picture gallery.
                        Task {
                            await refreshReferenceAfterMeasures()
                            await loadTechViews(triggeredByUser: true)
                        }
                    }
                )
            }
        }
        .sheet(isPresented: $showMetadataEditor) {
            metadataEditorSheet
        }
        .fullScreenCover(item: $zoomPresentation) { presentation in
            PictureZoomView(
                items: presentation.items,
                startIndex: presentation.startIndex
            ) {
                zoomPresentation = nil
            }
            .navigationTransition(.zoom(sourceID: presentation.id, in: pictureZoomNamespace))
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
                if let illustration = latestMeasurementPicture {
                    measurementIllustrationThumb(illustration) {
                        // Measures section has at most one thumbnail.
                        let items = buildZoomItems(ghosts: [], pictures: [illustration])
                        zoomPresentation = ZoomPresentation(items: items, startIndex: 0)
                    }
                } else if let pending = pendingMeasurementPreview {
                    measurementIllustrationGhost(pending.filename, pending.data) {
                        let items = buildZoomItems(ghosts: [pending], pictures: [])
                        zoomPresentation = ZoomPresentation(items: items, startIndex: 0)
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
            }
            .padding()
            .background(.background, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func formatted(_ value: ReferenceExtra.MeasureValue) -> String {
        String(format: "%.1f %@", value.value, value.unit)
    }

    /// The most recent picture in the loaded tech-views list
    /// whose filename matches the measurement filename pattern.
    /// `techViewPictures` is already sorted newest-first, so
    /// `.first(where:)` returns the latest.
    private var latestMeasurementPicture: Picture? {
        guard let reference = currentReferenceStock?.reference else { return nil }
        let pattern = settings.photoFilenameMeasurePattern
        return techViewPictures.first { picture in
            guard let filename = picture.matchableFilename else { return false }
            return TechViewsFilenameCounter.filename(
                filename,
                matches: pattern,
                ean: reference.ean,
                ref: reference.ref
            )
        }
    }

    /// Pending measurement-pattern preview rendered while GS is
    /// still registering the `Picture` row. Nil once GS catches up.
    private var pendingMeasurementPreview: (filename: String, data: Data)? {
        guard let reference = currentReferenceStock?.reference else { return nil }
        let pattern = settings.photoFilenameMeasurePattern
        return pendingPreviews(matching: { filename in
            TechViewsFilenameCounter.filename(
                filename,
                matches: pattern,
                ean: reference.ean,
                ref: reference.ref
            )
        }).first
    }

    @ViewBuilder
    private func measurementIllustrationThumb(_ picture: Picture, onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            pictureThumbnailContent(picture, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .frame(maxHeight: 320)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .matchedTransitionSource(id: "picture-\(picture.id)", in: pictureZoomNamespace)
    }

    @ViewBuilder
    private func measurementIllustrationGhost(_ filename: String, _ data: Data, onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            ZStack(alignment: .bottomLeading) {
                ghostImageContent(data: data, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: 320)
                uploadingBadge
                    .padding(8)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .matchedTransitionSource(id: "ghost-\(filename)", in: pictureZoomNamespace)
    }

    // MARK: - Metadata (extra.tech_views structured text)

    /// Mirrors the categories in `TechViewCategory` against the
    /// `extra.tech_views` blob on the reference. Only categories
    /// with a non-empty value get a row. Used by `metadataSection`.
    private var metadataEntries: [(category: TechViewCategory, value: String)] {
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

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Metadata")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    seedMetadataDrafts()
                    showMetadataEditor = true
                } label: {
                    Label("Edit", systemImage: "pencil")
                        .labelStyle(.titleAndIcon)
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            VStack(alignment: .leading, spacing: 12) {
                let entries = metadataEntries
                let labelPictures = ocrPictures
                let labelGhosts = pendingOCRPreviews
                let hasLabels = !labelPictures.isEmpty || !labelGhosts.isEmpty
                if entries.isEmpty && !hasLabels {
                    Label("No metadata yet", systemImage: "list.bullet.rectangle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(entries, id: \.category) { entry in
                        metadataRow(entry.category, value: entry.value)
                    }
                    if hasLabels {
                        if !entries.isEmpty {
                            Divider()
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Labels", systemImage: "text.viewfinder")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(spacing: 10) {
                                    let labelItems = buildZoomItems(
                                        ghosts: labelGhosts,
                                        pictures: labelPictures
                                    )
                                    ForEach(Array(labelGhosts.enumerated()), id: \.element.filename) { idx, ghost in
                                        techViewGhostThumbnail(filename: ghost.filename, data: ghost.data) {
                                            zoomPresentation = ZoomPresentation(
                                                items: labelItems,
                                                startIndex: idx
                                            )
                                        }
                                    }
                                    ForEach(Array(labelPictures.enumerated()), id: \.element.id) { idx, picture in
                                        techViewThumbnail(picture) {
                                            zoomPresentation = ZoomPresentation(
                                                items: labelItems,
                                                startIndex: labelGhosts.count + idx
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding()
            .background(.background, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func metadataRow(_ category: TechViewCategory, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(category.displayName, systemImage: category.symbolName)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Tech views (picture gallery filtered by shooting method)

    private var techViewsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Tech views")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            VStack(alignment: .leading, spacing: 12) {
                let pictures = presentationAndDetailPictures
                let ghosts = pendingTechViewPreviews
                let isEmpty = pictures.isEmpty && ghosts.isEmpty
                if techViewsLoadStatus != .loaded {
                    techViewsLookupBanner
                } else if isEmpty {
                    Label("No tech-view pictures yet", systemImage: "photo.stack")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 10) {
                            let techItems = buildZoomItems(ghosts: ghosts, pictures: pictures)
                            ForEach(Array(ghosts.enumerated()), id: \.element.filename) { idx, ghost in
                                techViewGhostThumbnail(filename: ghost.filename, data: ghost.data) {
                                    zoomPresentation = ZoomPresentation(
                                        items: techItems,
                                        startIndex: idx
                                    )
                                }
                            }
                            ForEach(Array(pictures.enumerated()), id: \.element.id) { idx, picture in
                                techViewThumbnail(picture) {
                                    zoomPresentation = ZoomPresentation(
                                        items: techItems,
                                        startIndex: ghosts.count + idx
                                    )
                                }
                            }
                        }
                    }
                }
                Button {
                    showTechViewsCapture = true
                } label: {
                    Label(
                        isEmpty ? "Capture tech views" : "Add more tech views",
                        systemImage: isEmpty ? "camera.viewfinder" : "plus"
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

    /// Pictures uploaded for the current reference that DON'T
    /// belong to the Measurement or OCR filename patterns —
    /// effectively the Presentation + Detail captures plus any
    /// freeform upload that doesn't match either of the two
    /// dedicated patterns.
    private var presentationAndDetailPictures: [Picture] {
        guard let reference = currentReferenceStock?.reference else { return [] }
        let measurePattern = settings.photoFilenameMeasurePattern
        let ocrPattern = settings.photoFilenameOCRPattern
        let filtered = techViewPictures.filter { picture in
            // No matchable filename → keep the picture in the
            // Tech-views bucket (safer than dropping it silently).
            guard let filename = picture.matchableFilename else { return true }
            let isMeasure = TechViewsFilenameCounter.filename(
                filename,
                matches: measurePattern,
                ean: reference.ean,
                ref: reference.ref
            )
            let isOCR = TechViewsFilenameCounter.filename(
                filename,
                matches: ocrPattern,
                ean: reference.ean,
                ref: reference.ref
            )
            return !isMeasure && !isOCR
        }
        return sortedDedupedForDisplay(filtered)
    }

    /// Ghost previews matching the Presentation/Detail patterns
    /// — i.e. anything that's neither OCR nor Measurement. Mirrors
    /// the filter on `presentationAndDetailPictures`.
    private var pendingTechViewPreviews: [(filename: String, data: Data)] {
        guard let reference = currentReferenceStock?.reference else { return [] }
        let measurePattern = settings.photoFilenameMeasurePattern
        let ocrPattern = settings.photoFilenameOCRPattern
        return pendingPreviews(matching: { filename in
            let isMeasure = TechViewsFilenameCounter.filename(
                filename, matches: measurePattern, ean: reference.ean, ref: reference.ref
            )
            let isOCR = TechViewsFilenameCounter.filename(
                filename, matches: ocrPattern, ean: reference.ean, ref: reference.ref
            )
            return !isMeasure && !isOCR
        })
    }

    /// Ghost previews for the OCR/label pattern, shown in the
    /// Metadata Labels strip while GS finishes registering them.
    private var pendingOCRPreviews: [(filename: String, data: Data)] {
        guard let reference = currentReferenceStock?.reference else { return [] }
        let ocrPattern = settings.photoFilenameOCRPattern
        return pendingPreviews(matching: { filename in
            TechViewsFilenameCounter.filename(
                filename, matches: ocrPattern, ean: reference.ean, ref: reference.ref
            )
        })
    }

    /// OCR / label pictures uploaded for the current reference.
    /// Rendered in the Metadata section so the user sees the
    /// source material the structured `extra.tech_views` text
    /// was extracted from.
    private var ocrPictures: [Picture] {
        guard let reference = currentReferenceStock?.reference else { return [] }
        let ocrPattern = settings.photoFilenameOCRPattern
        let filtered = techViewPictures.filter { picture in
            guard let filename = picture.matchableFilename else { return false }
            return TechViewsFilenameCounter.filename(
                filename,
                matches: ocrPattern,
                ean: reference.ean,
                ref: reference.ref
            )
        }
        return sortedDedupedForDisplay(filtered)
    }

    /// Builds the carousel item list shown when the user taps a
    /// thumbnail in a section. Ghosts come first (matching the
    /// on-screen render order), then the GS-backed pictures.
    private func buildZoomItems(
        ghosts: [(filename: String, data: Data)],
        pictures: [Picture]
    ) -> [ZoomableItem] {
        var items: [ZoomableItem] = []
        items.reserveCapacity(ghosts.count + pictures.count)
        for ghost in ghosts {
            items.append(ZoomableItem(
                id: "ghost-\(ghost.filename)",
                filename: ghost.filename,
                imageURL: nil,
                localData: ghost.data
            ))
        }
        for picture in pictures {
            items.append(ZoomableItem(
                id: "picture-\(picture.id)",
                filename: picture.matchableFilename,
                imageURL: picture.thumbnailURL,
                localData: localData(for: picture)
            ))
        }
        return items
    }

    /// Collapses duplicate-filename entries to the newest one (we
    /// rely on `techViewPictures` being newest-first) and returns
    /// the survivors sorted by ascending `smalltext`. The user
    /// wanted the gallery to read in filename order rather than
    /// in upload-time order.
    private func sortedDedupedForDisplay(_ pictures: [Picture]) -> [Picture] {
        var seen: Set<String> = []
        var deduped: [Picture] = []
        for picture in pictures {
            // No filename → treat each row as unique (can't
            // dedupe). Use a sentinel keyed by id.
            let key = picture.matchableFilename ?? "picture_id:\(picture.id)"
            if seen.insert(key).inserted {
                deduped.append(picture)
            }
        }
        return deduped.sorted { lhs, rhs in
            (lhs.matchableFilename ?? "") < (rhs.matchableFilename ?? "")
        }
    }

    @ViewBuilder
    private func techViewThumbnail(_ picture: Picture, onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            pictureThumbnailContent(picture, contentMode: .fill)
                .frame(width: 120, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .matchedTransitionSource(id: "picture-\(picture.id)", in: pictureZoomNamespace)
    }

    /// Renders a local-only "ghost" thumbnail for a freshly-uploaded
    /// picture whose GS `Picture` row hasn't surfaced yet. Identical
    /// frame + tap behaviour as `techViewThumbnail` so the user
    /// doesn't see a layout shift when the row eventually arrives.
    @ViewBuilder
    private func techViewGhostThumbnail(filename: String, data: Data, onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            ZStack(alignment: .bottomLeading) {
                ghostImageContent(data: data, contentMode: .fill)
                    .frame(width: 120, height: 120)
                uploadingBadge
                    .padding(6)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .matchedTransitionSource(id: "ghost-\(filename)", in: pictureZoomNamespace)
    }

    /// Small "Uploading…" pill drawn on top of a ghost thumbnail
    /// so the user understands the picture is uploading and will
    /// be replaced by the GS-served copy shortly.
    private var uploadingBadge: some View {
        HStack(spacing: 4) {
            ProgressView().controlSize(.mini).tint(.white)
            Text("Uploading…")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.black.opacity(0.7), in: Capsule())
    }

    @ViewBuilder
    private func ghostImageContent(data: Data, contentMode: ContentMode) -> some View {
        if let ui = UIImage(data: data) {
            Image(uiImage: ui)
                .resizable()
                .aspectRatio(contentMode: contentMode)
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
                .overlay(
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                )
        }
    }

    /// Filename → cached JPEG lookup for the picture. Keyed by
    /// `smalltext` (preserved by GS) — see `Picture.matchableFilename`.
    private func localData(for picture: Picture) -> Data? {
        guard let filename = picture.matchableFilename else { return nil }
        return localCapturePreviews[filename]
    }

    /// Returns local-cache entries whose filename satisfies
    /// `match` AND that don't yet have a corresponding GS Picture
    /// row in `techViewPictures`. Sorted by ascending filename to
    /// match the display order of the GS-backed gallery.
    private func pendingPreviews(matching match: (String) -> Bool) -> [(filename: String, data: Data)] {
        let knownFilenames: Set<String> = Set(
            techViewPictures.compactMap { $0.matchableFilename }
        )
        return localCapturePreviews
            .filter { entry in match(entry.key) && !knownFilenames.contains(entry.key) }
            .map { (filename: $0.key, data: $0.value) }
            .sorted { $0.filename < $1.filename }
    }

    /// Resolves a thumbnail image for `picture`. Preference order:
    /// 1. The GS CDN `thumbnail` URL when GS has finished generating it.
    /// 2. A locally-cached JPEG from a just-completed upload, so the
    ///    user sees their shot the instant they exit the capture flow.
    /// 3. A grey placeholder as a last resort.
    @ViewBuilder
    private func pictureThumbnailContent(
        _ picture: Picture,
        contentMode: ContentMode
    ) -> some View {
        let placeholder = RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.secondary.opacity(0.12))
        let localData = self.localData(for: picture)
        if let url = picture.thumbnailURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: contentMode)
                case .failure:
                    fallbackLocalOrPlaceholder(localData: localData, contentMode: contentMode, placeholder: placeholder)
                case .empty:
                    if let localData {
                        localImage(localData, contentMode: contentMode)
                    } else {
                        placeholder.overlay(ProgressView().controlSize(.small))
                    }
                @unknown default:
                    placeholder
                }
            }
        } else if let localData {
            localImage(localData, contentMode: contentMode)
        } else {
            placeholder.overlay(
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            )
        }
    }

    @ViewBuilder
    private func fallbackLocalOrPlaceholder<P: View>(
        localData: Data?,
        contentMode: ContentMode,
        placeholder: P
    ) -> some View {
        if let localData {
            localImage(localData, contentMode: contentMode)
        } else {
            placeholder.overlay(
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            )
        }
    }

    @ViewBuilder
    private func localImage(_ data: Data, contentMode: ContentMode) -> some View {
        if let ui = UIImage(data: data) {
            Image(uiImage: ui)
                .resizable()
                .aspectRatio(contentMode: contentMode)
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
                .overlay(
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                )
        }
    }

    private var techViewsLookupBanner: some View {
        retryBanner(
            status: techViewsLoadStatus,
            failedTitle: "Couldn't load tech-view pictures.",
            refreshingTitle: "Reloading tech-view pictures…",
            retry: { Task { await loadTechViews(triggeredByUser: true) } }
        )
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
                let rows = shotListRows
                // One carousel for the whole section: all pictures
                // present in the rows, in row order. Missing rows
                // (no picture) don't contribute to the carousel.
                let pictures = rows.compactMap(\.picture)
                let items = buildZoomItems(ghosts: [], pictures: pictures)
                ForEach(rows, id: \.id) { row in
                    ShotListRow(row: row, namespace: pictureZoomNamespace) {
                        guard let picture = row.picture,
                              let idx = pictures.firstIndex(where: { $0.id == picture.id })
                        else { return }
                        zoomPresentation = ZoomPresentation(
                            items: items,
                            startIndex: idx
                        )
                    }
                }
            }
        }
    }

    private var picturesLatest: [Picture] {
        // Exclude rows that belong to the tech-views shooting
        // method — those are already surfaced in the Tech views /
        // Labels / Measures sections above. The `/picture` API
        // doesn't filter by shooting-method id, only by name; we
        // already have the matching name in DevSettings so the
        // client-side filter has zero extra cost.
        let techViewsMethod = settings.techViewsShootingMethodName
        return pictures
            .latestByFilePath()
            .filter { picture in
                guard let techViewsMethod else { return true }
                return picture.shootingmethod != techViewsMethod
            }
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
            pictures = try await Self.loadWithRetry { try await service.list(forRef: ref) }
            picturesLoadStatus = .loaded
        } catch {
            picturesLoadStatus = .failed
            if !triggeredByUser {
                schedulePicturesAutoRetry()
            }
        }
    }

    /// Retries `operation` with short backoff before propagating
    /// the final error, so transient GS slowness doesn't surface
    /// a banner the user has to dismiss. Three attempts total
    /// (initial + two retries spaced 0.8 s / 1.8 s). Any failure
    /// after the third attempt is bubbled up to the caller and
    /// the caller's existing banner / auto-retry kicks in.
    @MainActor
    static func loadWithRetry<T>(
        attempts: Int = 3,
        delays: [Duration] = [.milliseconds(800), .milliseconds(1800)],
        operation: () async throws -> T
    ) async throws -> T {
        var lastError: Error?
        for attempt in 0..<attempts {
            do {
                return try await operation()
            } catch {
                lastError = error
                if attempt < attempts - 1 {
                    let delay = delays[min(attempt, delays.count - 1)]
                    try? await Task.sleep(for: delay)
                }
            }
        }
        throw lastError ?? CancellationError()
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

    // MARK: - Tech-views loader

    /// Fetches the picture gallery for the current reference,
    /// scoped to the active shooting method. Same retry semantics
    /// as `loadPictures`: initial failure schedules an auto-retry
    /// 5 s later; manual triggers cancel any pending auto-retry.
    /// Skipped silently when there's no shooting method
    /// configured or no reference yet — the section in that case
    /// shows the "configure shooting method" hint instead of a
    /// load error.
    @MainActor
    private func loadTechViews(triggeredByUser: Bool) async {
        guard let ref = currentReferenceStock?.reference.ref,
              let methodName = settings.techViewsShootingMethodName
        else {
            techViewPictures = []
            techViewsLoadStatus = .loaded
            return
        }
        if triggeredByUser { techViewsRetryTask?.cancel() }
        techViewsLoadStatus = .refreshing
        let service = PictureService(environment: settings.currentEnvironment)
        do {
            let raw = try await Self.loadWithRetry {
                try await service.listTechViews(
                    forRef: ref,
                    shootingMethodName: methodName
                )
            }
            // The /picture endpoint can return multiple rows per
            // physical file (one per status change). Collapse so
            // we only show one thumbnail per uploaded shot.
            techViewPictures = raw.latestByFilePath().sorted { lhs, rhs in
                (lhs.dateCre ?? "") > (rhs.dateCre ?? "")
            }
            techViewsLoadStatus = .loaded
        } catch {
            techViewsLoadStatus = .failed
            if !triggeredByUser {
                scheduleTechViewsAutoRetry()
            }
        }
    }

    private func scheduleTechViewsAutoRetry() {
        techViewsRetryTask?.cancel()
        techViewsRetryTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            if Task.isCancelled { return }
            guard techViewsLoadStatus == .failed else { return }
            await loadTechViews(triggeredByUser: false)
        }
    }

    // MARK: - Metadata editor sheet

    private func seedMetadataDrafts() {
        let tv = currentReferenceStock?.reference.extra?.techViews
        metadataDrafts = [
            TechViewCategory.provenance.rawValue:   tv?.provenance ?? "",
            TechViewCategory.composition.rawValue:  tv?.composition ?? "",
            TechViewCategory.care.rawValue:         tv?.care ?? "",
            TechViewCategory.standards.rawValue:    tv?.standards ?? "",
            TechViewCategory.restrictions.rawValue: tv?.restrictions ?? "",
            TechViewCategory.notes.rawValue:        tv?.notes ?? ""
        ]
        metadataSaveError = nil
    }

    private var metadataEditorSheet: some View {
        NavigationStack {
            Form {
                ForEach(TechViewCategory.allCases) { category in
                    Section {
                        TextField(
                            "",
                            text: Binding(
                                get: { metadataDrafts[category.rawValue] ?? "" },
                                set: { metadataDrafts[category.rawValue] = $0 }
                            ),
                            axis: .vertical
                        )
                        .textInputAutocapitalization(.sentences)
                        .autocorrectionDisabled(false)
                        .lineLimit(1...6)
                    } header: {
                        Label(category.displayName, systemImage: category.symbolName)
                    }
                }
                if let metadataSaveError {
                    Section {
                        Label(metadataSaveError, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Edit metadata")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showMetadataEditor = false }
                        .disabled(metadataSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if metadataSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Save") {
                            Task { await saveMetadataDrafts() }
                        }
                    }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        UIApplication.shared.sendAction(
                            #selector(UIResponder.resignFirstResponder),
                            to: nil, from: nil, for: nil
                        )
                    }
                }
            }
        }
    }

    @MainActor
    private func saveMetadataDrafts() async {
        guard let referenceID = currentReferenceStock?.reference.id else {
            metadataSaveError = "Reference id unavailable."
            return
        }
        // Only send categories whose draft has actual content;
        // ReferenceExtraService merges with whatever's already on
        // GS, so leaving a key out preserves any prior value.
        var payload: [String: String] = [:]
        for category in TechViewCategory.allCases {
            let trimmed = (metadataDrafts[category.rawValue] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                payload[category.rawValue] = trimmed
            }
        }
        metadataSaving = true
        metadataSaveError = nil
        defer { metadataSaving = false }
        let service = ReferenceExtraService(environment: settings.currentEnvironment)
        do {
            try await service.updateTechViews(referenceID: referenceID, fields: payload)
            showMetadataEditor = false
            // Pull the freshly-saved values back into the
            // displayed reference so the row list reflects them.
            await refreshReferenceAfterMeasures()
        } catch let err as GSHTTPClient.HTTPError {
            metadataSaveError = err.userMessage
        } catch {
            metadataSaveError = error.localizedDescription
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
            let matches = try await Self.loadWithRetry {
                try await service.search(
                    scannedValue: context.payload,
                    by: context.attribute
                )
            }
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
    let namespace: Namespace.ID
    /// Tap handler for the thumbnail — open the carousel at this
    /// row's picture. Nil-out by passing a no-op when the row has
    /// no picture; the thumbnail will render as a placeholder and
    /// the button is disabled.
    let onTapThumbnail: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            thumbnailButton
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
    private var thumbnailButton: some View {
        if let picture = row.picture {
            Button(action: onTapThumbnail) {
                thumbnail
            }
            .buttonStyle(.plain)
            .matchedTransitionSource(id: "picture-\(picture.id)", in: namespace)
        } else {
            thumbnail
        }
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
