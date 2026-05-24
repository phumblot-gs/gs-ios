#if os(iOS)
import SwiftUI
import simd
import GSScanner
import GSAPIClient
import GSCore

/// Final step of the measure flow. Shows the détouré reference photo
/// (kept subjects on white) with each captured measurement drawn as a
/// segment between two reprojected endpoints, plus a list of values.
/// "Attach to a reference" scans / picks a Grand Shooting reference and
/// posts the values via `PUT /reference/:id/extra`.
struct MeasureSummaryView: View {
    let settings: DevSettings
    @Bindable var category: MeasureCategory
    let referenceFrame: CapturedFrame
    let includedSubjects: [DetectedSubject]
    let captures: [MeasurementCapture]
    /// When set, the save step is bound to this reference: a single
    /// "Save" button on the form, no scanner sheet. The detail screen
    /// that opened this flow already knows which reference we're on.
    let attachedTo: Reference?
    let onDone: @MainActor () -> Void
    /// Called as soon as the illustration JPEG + filename are
    /// computed, BEFORE the multipart upload to GS. Lets the
    /// reference detail cache the local preview so the just-saved
    /// shot renders immediately on return, even if the upload is
    /// still in flight or GS hasn't generated the CDN thumbnail yet.
    let onIllustrationReady: @MainActor (LocalCapturePreview) -> Void

    @State private var cutoutImage: UIImage?
    @State private var resolveSheetVisible = false
    @State private var saving = false
    @State private var saveError: String?

    var body: some View {
        Form {
            previewSection
            gsLinkSection
            measurementsSection
            saveSection
            if let saveError {
                Section {
                    Label(saveError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }
        }
        .navigationTitle("Validate")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if cutoutImage == nil {
                cutoutImage = MeasureSubjectCutout.make(
                    frame: referenceFrame,
                    includedSubjects: includedSubjects
                )
            }
        }
        .sheet(isPresented: $resolveSheetVisible) {
            NavigationStack {
                ReferenceScanForMeasures(settings: settings) { ref in
                    resolveSheetVisible = false
                    Task { await save(toReference: ref) }
                }
            }
        }
    }

    // MARK: - Sections

    private var previewSection: some View {
        Section {
            ZStack {
                Image(uiImage: cutoutImage ?? referenceFrame.image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 320)

                GeometryReader { geometry in
                    let rect = renderedRect(in: geometry.size, imageSize: referenceFrame.image.size)
                    SegmentsOverlay(
                        captures: captures,
                        frame: referenceFrame,
                        viewRect: rect
                    )
                }
            }
        } header: {
            Text("Reference photo")
        } footer: {
            Text("Segments are reprojected onto the original photo from the LiDAR world coordinates captured during placement.")
        }
    }

    private var gsLinkSection: some View {
        Section {
            GSCategoryLinkRow(selection: $category.gsCategoryID)
        } header: {
            Text("Grand Shooting link")
        } footer: {
            Text("Pick the Grand Shooting catalog category these measurements belong to. The link is saved on the local category for future captures.")
        }
    }

    private var measurementsSection: some View {
        Section {
            HStack {
                Image(systemName: "tag.fill").foregroundStyle(.tint)
                Text(category.name).font(.headline)
            }
            ForEach(orderedRows) { row in
                HStack {
                    Text(row.name)
                    Spacer()
                    Text(format(meters: row.meters))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Measurements")
        }
    }

    @ViewBuilder
    private var saveSection: some View {
        if let attachedTo {
            Section {
                Button {
                    Task { await save(toReference: attachedTo) }
                } label: {
                    if saving {
                        HStack { ProgressView(); Text("Saving…") }
                    } else {
                        Label("Save measurements", systemImage: "checkmark.seal.fill")
                    }
                }
                .disabled(saving)
            } header: {
                Text("Reference")
            } footer: {
                Text("Will save these measurements as `extra.measures` on \(attachedTo.ref).")
            }
        } else {
            Section {
                Button {
                    resolveSheetVisible = true
                } label: {
                    if saving {
                        HStack { ProgressView(); Text("Saving…") }
                    } else {
                        Label("Attach to a reference", systemImage: "link.badge.plus")
                    }
                }
                .disabled(saving)
            } footer: {
                Text("Scan or pick a reference to save these measurements as `extra.measures` on Grand Shooting.")
            }
        }
    }

    // MARK: - Data

    private var orderedRows: [Row] {
        captures
            .sorted(by: { $0.order < $1.order })
            .map { Row(id: $0.id, name: $0.templateName, meters: $0.meters) }
    }

    private struct Row: Identifiable {
        let id: UUID
        let name: String
        let meters: Float
    }

    private func format(meters: Float) -> String {
        let value = settings.measurementUnit.convert(meters: Double(meters))
        return String(format: "%.1f %@", value, settings.measurementUnit.apiSymbol)
    }

    /// Compute the rect a `scaledToFit` image occupies inside `viewSize`,
    /// matching the SegmentsOverlay's drawing rect.
    private func renderedRect(in viewSize: CGSize, imageSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGRect(origin: .zero, size: viewSize)
        }
        let imageAspect = imageSize.width / imageSize.height
        let viewAspect = viewSize.width / viewSize.height
        let renderedSize: CGSize
        if imageAspect > viewAspect {
            renderedSize = CGSize(width: viewSize.width, height: viewSize.width / imageAspect)
        } else {
            renderedSize = CGSize(width: viewSize.height * imageAspect, height: viewSize.height)
        }
        let origin = CGPoint(
            x: (viewSize.width - renderedSize.width) / 2,
            y: (viewSize.height - renderedSize.height) / 2
        )
        return CGRect(origin: origin, size: renderedSize)
    }

    // MARK: - Save

    @MainActor
    private func save(toReference reference: Reference) async {
        guard let referenceID = reference.id else {
            saveError = String(localized: "Reference is missing a reference_id.")
            return
        }
        saving = true
        saveError = nil

        var payload: [String: ReferenceExtraService.MeasureValue] = [:]
        let unit = settings.measurementUnit
        for capture in captures where capture.isComplete {
            let value = unit.convert(meters: Double(capture.meters))
            let rounded = (value * 10).rounded() / 10
            payload[capture.templateName] = .init(value: rounded, unit: unit.apiSymbol)
        }

        let service = ReferenceExtraService(environment: settings.currentEnvironment)
        do {
            try await service.updateMeasures(referenceID: referenceID, measures: payload)
            saving = false

            // Fire the illustration render + upload after we hand
            // control back to the parent. Captures everything by
            // value so the closure doesn't need the view to stay
            // alive past `onDone()`.
            let env = settings.currentEnvironment
            let methodID = settings.techViewsShootingMethodID
            let methodName = settings.techViewsShootingMethodName
            let pattern = settings.photoFilenameMeasurePattern
            let measureUnit = settings.measurementUnit
            let frame = referenceFrame
            let subjectsSnapshot = includedSubjects
            let capturesSnapshot = captures
            let refSnapshot = reference
            let onReady = onIllustrationReady
            Task { @MainActor in
                await Self.renderAndUploadIllustration(
                    environment: env,
                    shootingMethodID: methodID,
                    shootingMethodName: methodName,
                    filenamePattern: pattern,
                    unit: measureUnit,
                    frame: frame,
                    subjects: subjectsSnapshot,
                    captures: capturesSnapshot,
                    reference: refSnapshot,
                    onIllustrationReady: onReady
                )
            }

            // Auto-dismiss back to the reference detail — the
            // success state is conveyed by the refreshed
            // `extra.measures` row showing up there.
            onDone()
        } catch let err as GSHTTPClient.HTTPError {
            saving = false
            saveError = err.userMessage
        } catch {
            saving = false
            saveError = error.localizedDescription
        }
    }

    /// Static so the background task doesn't keep the view alive.
    /// Renders the illustration on the main actor (UIKit-bound),
    /// then hops off-main for the multipart upload.
    @MainActor
    private static func renderAndUploadIllustration(
        environment: GSEnvironment,
        shootingMethodID: Int?,
        shootingMethodName: String?,
        filenamePattern: String,
        unit: DevSettings.MeasurementUnit,
        frame: CapturedFrame,
        subjects: [DetectedSubject],
        captures: [MeasurementCapture],
        reference: Reference,
        onIllustrationReady: @MainActor (LocalCapturePreview) -> Void
    ) async {
        guard let shootingMethodID else {
            // No shooting method configured — silently skip the
            // upload. The measures themselves are already saved.
            return
        }
        let cutout = MeasureSubjectCutout.make(
            frame: frame,
            includedSubjects: subjects
        )
        let illustration = MeasureIllustration.render(
            cutout: cutout,
            frame: frame,
            captures: captures,
            unit: unit
        )
        let resized = illustration.resized(toMaxDimension: 1200)
        guard let jpegData = resized.jpegData(compressionQuality: 0.9) else { return }

        // Seed the inc counter against today's existing GS
        // uploads for this reference + shooting method so the
        // measurement image doesn't overwrite a previously
        // captured shot (tech-view or otherwise) when the user
        // configured the same pattern for several modes.
        var counter = TechViewsFilenameCounter()
        if let shootingMethodName {
            let pictureService = PictureService(environment: environment)
            if let existing = try? await pictureService.filenamesUploadedToday(
                forRef: reference.ref,
                shootingMethodName: shootingMethodName
            ) {
                counter.seed(
                    from: existing,
                    patterns: [filenamePattern],
                    ean: reference.ean,
                    ref: reference.ref
                )
            }
        }
        let filename = counter.take(
            pattern: filenamePattern,
            ean: reference.ean,
            ref: reference.ref
        )

        // Hand the local preview up to the reference detail BEFORE
        // we wait on the network — even if the upload is slow or
        // GS is slow to generate the CDN thumbnail, the gallery
        // can paint pixels straight away.
        onIllustrationReady(
            LocalCapturePreview(filename: filename, jpegData: jpegData)
        )

        do {
            let productionService = ProductionService(environment: environment)
            let production = try await productionService.findOrCreateToday(shootingMethodID: shootingMethodID)
            let uploadService = ProductionUploadService(environment: environment)
            try await uploadService.upload(
                jpegData: jpegData,
                filename: filename,
                productionRootID: production.rootID
            )
        } catch {
            print("[Measure] illustration upload failed: \(error.localizedDescription)")
        }
    }
}

private extension UIImage {
    func resized(toMaxDimension maxDimension: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxDimension else { return self }
        let scale = maxDimension / longest
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}

// MARK: - Segments overlay

/// Draws every captured measurement as a green segment with circle
/// endpoints and a numeric label centered on the segment.
private struct SegmentsOverlay: View {
    let captures: [MeasurementCapture]
    let frame: CapturedFrame
    let viewRect: CGRect

    var body: some View {
        ZStack {
            ForEach(captures) { capture in
                if capture.worldPoints.count >= 2 {
                    SegmentView(
                        worldPoints: capture.worldPoints,
                        frame: frame,
                        viewRect: viewRect
                    )
                }
            }
        }
    }
}

private struct SegmentView: View {
    let worldPoints: [SIMD3<Float>]
    let frame: CapturedFrame
    let viewRect: CGRect

    var body: some View {
        if let projected = projectAll() {
            ZStack {
                Path { path in
                    path.move(to: projected[0])
                    for p in projected.dropFirst() { path.addLine(to: p) }
                }
                .stroke(.green, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))

                ForEach(projected.indices, id: \.self) { idx in
                    Circle()
                        .fill(.green)
                        .frame(width: 10, height: 10)
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                        .position(projected[idx])
                }
            }
        }
    }

    private func projectAll() -> [CGPoint]? {
        var pts: [CGPoint] = []
        for world in worldPoints {
            guard let n = MeasureReprojection.projectToNormalized(worldPoint: world, frame: frame) else {
                return nil
            }
            pts.append(CGPoint(
                x: viewRect.minX + n.x * viewRect.width,
                y: viewRect.minY + n.y * viewRect.height
            ))
        }
        return pts
    }
}

// MARK: - Reference selection (embedded scanner + manual entry)

private struct ReferenceScanForMeasures: View {
    let settings: DevSettings
    let onResolved: @MainActor (Reference) -> Void

    @State private var manualValue = ""
    @State private var isLookingUp = false
    @State private var error: String?
    @State private var feedback = ScannerFeedback()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .bottom) {
            LiveBarcodeScannerView(resetDelaySeconds: 0.5) { code in
                Task { await resolve(value: code.payload) }
            }
            .ignoresSafeArea()

            VStack(spacing: 10) {
                if isLookingUp {
                    HStack { ProgressView().tint(.white); Text("Looking up…").foregroundStyle(.white) }
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.black.opacity(0.6), in: Capsule())
                }
                if let error {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(8)
                        .background(.thinMaterial, in: Capsule())
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
        .navigationTitle("Attach to reference")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Cancel") { dismiss() }
            }
        }
    }

    @MainActor
    private func resolve(value: String) async {
        guard !isLookingUp else { return }
        isLookingUp = true
        error = nil
        defer { isLookingUp = false }
        feedback.didDetectCode()

        let service = ReferenceLookupService(environment: settings.currentEnvironment)
        do {
            let refs = try await service.lookup(scannedValue: value, by: settings.searchAttribute)
            if let first = refs.first {
                feedback.didFindReference()
                onResolved(first)
            } else {
                feedback.didFailLookup(reason: .notFound)
                error = "No reference for \(value)."
            }
        } catch let err as GSHTTPClient.HTTPError {
            feedback.didFailLookup(reason: .transport)
            error = err.userMessage
        } catch let other {
            feedback.didFailLookup(reason: .other)
            error = other.localizedDescription
        }
    }
}
#endif
