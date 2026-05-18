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
    @State private var picturesLoading = false
    @State private var picturesError: (any Error)?
    @State private var statusSheetVisible = false
    @State private var statusUpdating = false

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
                if !stockItems.isEmpty {
                    stockItemSection
                }
                shotListSection
            }
            .padding()
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(.systemGroupedBackground))
        .task {
            if references.isEmpty { references = sourceReferences }
            await loadPictures()
        }
        .sheet(isPresented: $statusSheetVisible) {
            statusPicker
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

    // MARK: - Shot list

    private var shotListSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pictures")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            if picturesLoading {
                ProgressView().frame(maxWidth: .infinity, alignment: .center)
            } else if let err = picturesError {
                Label("Couldn't load pictures: \(err.localizedDescription)", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.red)
            } else {
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

    @MainActor
    private func loadPictures() async {
        pictures = []
        picturesError = nil
        guard let ref = currentReferenceStock?.reference.ref else { return }
        picturesLoading = true
        defer { picturesLoading = false }
        do {
            let service = PictureService(environment: settings.currentEnvironment)
            pictures = try await service.list(forRef: ref)
        } catch {
            picturesError = error
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
            picturesError = NSError(domain: "GSHTTPClient", code: -1, userInfo: [NSLocalizedDescriptionKey: err.userMessage])
        } catch {
            picturesError = error
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
