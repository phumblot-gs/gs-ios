import SwiftUI
import SwiftData
import GSCamera
import GSAPIClient
import GSCore
import ImageIO
import UniformTypeIdentifiers
import UIKit

/// Capture loop for a single reference. Live camera preview with a
/// shutter; after each shot Vision runs OCR on the still in the
/// background while the user reviews the result on the annotation
/// sheet. Once OCR has the text boxes, a second Vision pass tries to
/// detect non-textual pictogram candidates and matches them against
/// the learned picto library. The user tags any extracted text + any
/// detected picto with one of six tech-view categories, then taps
/// "Save" — the photo uploads to today's production under
/// `<ref>_<inc>.jpg`, the categorised text + picto labels are pushed
/// to `extra.tech_views` on the reference, and any freshly-labelled
/// pictos are persisted locally so they auto-match next time. Both
/// network calls fire in parallel and don't block the next shot.
struct TechViewsCaptureView: View {
    @Bindable var settings: DevSettings
    let reference: Reference
    let onExit: @MainActor () -> Void

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \LearnedPictogram.createdAt, order: .reverse) private var learnedPictograms: [LearnedPictogram]

    @StateObject private var shutter = CameraShutter()
    @State private var pending: PendingShot?
    @State private var observations: [OCRObservation] = []
    @State private var assignments: [UUID: TechViewCategory] = [:]
    @State private var ocrEdits: [UUID: String] = [:]
    @State private var hiddenOCRIDs: Set<UUID> = []
    @State private var pendingMode: CaptureMode = .presentation
    @State private var isRunningOCR: Bool = false
    @State private var isDetectingPictos: Bool = false
    @State private var candidates: [TechViewsPictoDetection.Candidate] = []
    @State private var pictoAnnotations: [UUID: PictoAnnotation] = [:]
    @State private var analysisTask: Task<Void, Never>?
    /// Seeded from today's GS production at `.task` time, then
    /// incremented per capture. Per-pattern slot so the same
    /// counter is shared across modes whose user-customised
    /// patterns happen to produce the same filename family.
    @State private var filenameCounter = TechViewsFilenameCounter()
    @State private var isSeedingCounter = true
    @State private var uploads: [UploadStatus] = []

    private struct PendingShot: Identifiable {
        let id = UUID()
        let image: UIImage
        let jpegData: Data
    }

    private struct UploadStatus: Identifiable, Equatable {
        let id = UUID()
        let filename: String
        var state: State

        enum State: Equatable {
            case inFlight
            case succeeded
            case failed(String)
        }
    }

    /// Builds the camera configuration we hand to GSCamera, picking
    /// the starting mode based on the user's persistence preference.
    private var initialCameraConfiguration: CameraConfiguration {
        let mode: CaptureMode
        switch settings.techViewsCapturePersistence {
        case .alwaysPresentation:
            mode = .presentation
        case .rememberLast:
            if let raw = settings.techViewsLastCaptureModeRaw,
               let last = CaptureMode(rawValue: raw) {
                mode = last
            } else {
                mode = .presentation
            }
        }
        return configuration(for: mode)
    }

    /// Builds the full `CameraConfiguration` for a given mode by
    /// pulling every relevant knob from `DevSettings`. Used both
    /// to seed the initial view and to push fresh configs through
    /// `shutter.applySettings(_:)` when the user toggles modes.
    private func configuration(for mode: CaptureMode) -> CameraConfiguration {
        let wb = PresentationWhiteBalance(rawValue: settings.techViewsWhiteBalanceRaw) ?? .auto
        let profile = PresentationColorProfile(rawValue: settings.techViewsColorProfileRaw) ?? .none
        let space = PresentationColorSpace(rawValue: settings.techViewsColorSpaceRaw) ?? .sRGB
        return CameraConfiguration(
            mode: mode,
            whiteBalance: wb,
            colorProfile: profile,
            colorSpace: space,
            targetFocalLength35mm: focalLength(for: mode)
        )
    }

    /// Maps a capture mode to its user-configured focal length
    /// (35mm equivalent). Used both when the camera view is first
    /// instantiated and when the user toggles modes mid-session.
    private func focalLength(for mode: CaptureMode) -> Int {
        switch mode {
        case .presentation: return settings.techViewsPresentationFocal
        case .detail: return settings.techViewsDetailFocal
        case .ocr: return settings.techViewsOCRFocal
        }
    }

    /// Filename template to use for a given capture mode.
    private func filenamePattern(for mode: CaptureMode) -> String {
        switch mode {
        case .presentation: return settings.photoFilenamePresentationPattern
        case .detail: return settings.photoFilenameDetailPattern
        case .ocr: return settings.photoFilenameOCRPattern
        }
    }

    private var allFilenamePatterns: [String] {
        [
            settings.photoFilenamePresentationPattern,
            settings.photoFilenameDetailPattern,
            settings.photoFilenameOCRPattern
        ]
    }

    /// True when the currently-active mode's focal target requires
    /// a digital zoom > 4× on the device's available lenses.
    /// Drives the "qualité dégradée" toast at the top of the
    /// capture overlay.
    private var heavyZoomWarning: String? {
        let target = focalLength(for: shutter.mode)
        let lenses = CameraInspector.availableBackLenses()
        guard let choice = CameraInspector.bestLens(forTargetFocal35mm: target, in: lenses) else {
            return nil
        }
        if choice.isTargetUnreachable {
            return "Cible \(target) mm impossible sur ce matériel — \(choice.lens.displayName) à \(choice.lens.nativeFocalLength35mm) mm appliqué."
        }
        if choice.requiresHeavyDigitalZoom {
            let zoom = String(format: "%.1f×", choice.zoomFactor)
            return "\(target) mm = crop numérique \(zoom). Qualité réduite."
        }
        return nil
    }

    var body: some View {
        ZStack {
            CameraView(shutter: shutter, configuration: initialCameraConfiguration) { photo in
                handleCapture(photo: photo)
            }
            .ignoresSafeArea()

            VStack {
                topBar
                if pending == nil, let warning = heavyZoomWarning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.orange.opacity(0.9), in: Capsule())
                        .padding(.top, 4)
                        .transition(.opacity)
                }
                Spacer()
                if pending == nil {
                    bottomControls
                }
            }

            if let pending {
                TechViewsAnnotationView(
                    image: pending.image,
                    captureMode: pendingMode,
                    observations: observations,
                    isRunningOCR: isRunningOCR,
                    candidates: candidates,
                    isDetectingPictos: isDetectingPictos,
                    assignments: $assignments,
                    ocrEdits: $ocrEdits,
                    hiddenOCRIDs: $hiddenOCRIDs,
                    pictoAnnotations: $pictoAnnotations,
                    onRetake: { retake() },
                    onSave: { save(pending: pending) }
                )
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: pending?.id)
        .navigationBarBackButtonHidden()
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await seedFilenameCounter()
        }
    }

    /// Pulls today's already-uploaded filenames from GS and feeds
    /// them into `filenameCounter` so the first capture's `{INC}`
    /// continues from whatever's already in the production rather
    /// than restarting at 1 (which would overwrite). Skipped
    /// silently when no shooting method is configured — the
    /// upload itself would fail in that case anyway.
    @MainActor
    private func seedFilenameCounter() async {
        defer { isSeedingCounter = false }
        guard let methodName = settings.techViewsShootingMethodName else { return }
        let service = PictureService(environment: settings.currentEnvironment)
        do {
            let existing = try await service.filenamesUploadedToday(
                forRef: reference.ref,
                shootingMethodName: methodName
            )
            filenameCounter.seed(
                from: existing,
                patterns: allFilenamePatterns,
                ean: reference.ean,
                ref: reference.ref
            )
        } catch {
            // Non-fatal: an inability to seed just means the
            // counter starts at 1 for each pattern. Worst case:
            // first capture overwrites an existing file. Logged
            // so we can investigate in dev.
            print("[TechViews] counter seed failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            Button {
                onExit()
            } label: {
                Image(systemName: "xmark")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(.black.opacity(0.5), in: Circle())
            }
            Spacer()
            VStack(spacing: 2) {
                Text(reference.displayName)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(reference.ref)
                    .font(.caption.monospaced())
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.black.opacity(0.5), in: Capsule())
            Spacer()
            uploadCountBadge
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var uploadCountBadge: some View {
        let successful = uploads.filter { $0.state == .succeeded }.count
        let inFlight = uploads.filter { $0.state == .inFlight }.count
        ZStack {
            Circle()
                .fill(.black.opacity(0.5))
                .frame(width: 44, height: 44)
            VStack(spacing: 0) {
                Text("\(successful)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                if inFlight > 0 {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.white)
                }
            }
        }
    }

    // MARK: - Bottom controls

    private var bottomControls: some View {
        VStack(spacing: 16) {
            if let last = uploads.last, case .failed(let message) = last.state {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.red.opacity(0.85), in: Capsule())
            }
            HStack(spacing: 24) {
                Spacer()
                modeToggleButton
                Button {
                    shutter.capture()
                } label: {
                    ZStack {
                        Circle().fill(.white).frame(width: 76, height: 76)
                        Circle().stroke(.white, lineWidth: 4).frame(width: 88, height: 88)
                    }
                }
                .disabled(shutter.isCapturing || shutter.authorization != .authorized || isSeedingCounter)
                .accessibilityLabel("Shutter")
                Spacer()
                    .overlay(alignment: .leading) {
                        // Mirror the toggle's width so the shutter
                        // stays optically centred.
                        Color.clear.frame(width: 56, height: 56)
                    }
            }
            .padding(.bottom, 32)
        }
    }

    private var modeToggleButton: some View {
        let current = shutter.mode
        let next = current.nextInRotation
        return Button {
            // Push the full configuration (including the focal
            // length picked for the new mode) so the session can
            // swap to the right physical lens + apply the right
            // digital zoom in one go.
            shutter.applySettings(configuration(for: next))
            if settings.techViewsCapturePersistence == .rememberLast {
                settings.techViewsLastCaptureModeRaw = next.rawValue
            }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: current.iconName)
                    .font(.title3.weight(.semibold))
                Text(current.shortLabel)
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(.white)
            .frame(width: 56, height: 56)
            .background(current.toggleBackground, in: Circle())
        }
        .disabled(shutter.isCapturing)
        .accessibilityLabel("Switch to \(next.shortLabel)")
    }

    // MARK: - Actions

    private func handleCapture(photo: CapturedPhoto) {
        guard let rawImage = UIImage(data: photo.imageData) else { return }
        // Bake any EXIF rotation into the pixel buffer so the
        // preview, OCR, picto detection and crop preview all see a
        // single .up-oriented coordinate space — no surprise
        // landscape view when the user holds the phone in portrait.
        let image = rawImage.normalizedUp()
        observations = []
        assignments = [:]
        ocrEdits = [:]
        hiddenOCRIDs = []
        candidates = []
        pictoAnnotations = [:]
        pendingMode = shutter.mode
        pending = PendingShot(image: image, jpegData: photo.imageData)

        // Vision OCR + picto detection only runs in OCR mode — the
        // other modes are normal product shots that just need an
        // upload after the user confirms.
        guard pendingMode == .ocr else {
            isRunningOCR = false
            isDetectingPictos = false
            analysisTask?.cancel()
            analysisTask = nil
            return
        }

        isRunningOCR = true
        isDetectingPictos = true
        analysisTask?.cancel()
        analysisTask = Task { @MainActor in
            await runAnalysis(on: image)
        }
    }

    @MainActor
    private func runAnalysis(on image: UIImage) async {
        // 1) OCR first so we know which regions are text and can
        //    exclude them from the picto detection pass.
        do {
            let ocrResult = try await TechViewsOCR.recognize(in: image)
            if Task.isCancelled { return }
            observations = ocrResult
            isRunningOCR = false
        } catch {
            if Task.isCancelled { return }
            observations = []
            isRunningOCR = false
        }

        // 2) Picto detection. Even if OCR failed we still try — the
        //    detector just gets an empty exclusion list.
        do {
            let textBoxes = observations.map(\.boundingBox)
            let detected = try await TechViewsPictoDetection.detect(
                in: image,
                excluding: textBoxes
            )
            if Task.isCancelled { return }
            candidates = detected
            pictoAnnotations = autoAnnotate(detected)
            isDetectingPictos = false
        } catch {
            if Task.isCancelled { return }
            candidates = []
            pictoAnnotations = [:]
            isDetectingPictos = false
        }
    }

    private func autoAnnotate(
        _ detected: [TechViewsPictoDetection.Candidate]
    ) -> [UUID: PictoAnnotation] {
        var out: [UUID: PictoAnnotation] = [:]
        for candidate in detected {
            guard let suggestion = TechViewsPictoMatcher.bestMatch(
                for: candidate,
                in: learnedPictograms
            ) else { continue }
            out[candidate.id] = PictoAnnotation(
                id: candidate.id,
                label: suggestion.label,
                category: TechViewCategory(rawValue: suggestion.categoryRawValue),
                matchedLearnedID: suggestion.learnedID,
                suggestionDistance: suggestion.distance
            )
        }
        return out
    }

    private func retake() {
        analysisTask?.cancel()
        analysisTask = nil
        pending = nil
        observations = []
        assignments = [:]
        ocrEdits = [:]
        hiddenOCRIDs = []
        candidates = []
        pictoAnnotations = [:]
        isRunningOCR = false
        isDetectingPictos = false
    }

    private func save(pending: PendingShot) {
        // Pick the pattern that matches the mode this shot was
        // taken in (NOT the current mode — the user may have
        // toggled while reviewing). Then ask the counter for the
        // next filename in that pattern's family.
        let pattern = filenamePattern(for: pendingMode)
        let filename = filenameCounter.take(
            pattern: pattern,
            ean: reference.ean,
            ref: reference.ref
        )
        let resized = pending.image.resized(toMaxDimension: 1200)
        // `UIImage.jpegData(compressionQuality:)` writes a minimal
        // JPEG — no EXIF, no TIFF, no Maker Note. Use ImageIO to
        // copy the source camera JPEG's property graph onto the
        // resized buffer so focal length, white-balance mode, ISO,
        // lens make + model survive the upload.
        guard let uploadData = encodeJPEGPreservingMetadata(
            image: resized,
            sourceJPEG: pending.jpegData,
            quality: 0.85
        ) else {
            self.pending = nil
            observations = []
            assignments = [:]
            ocrEdits = [:]
            candidates = []
            pictoAnnotations = [:]
            return
        }

        // Aggregate categorised text + picto labels per category.
        // OCR text honours any inline edits the user made.
        var fields: [String: [String]] = [:]
        for observation in observations {
            if hiddenOCRIDs.contains(observation.id) { continue }
            guard let category = assignments[observation.id] else { continue }
            let raw = ocrEdits[observation.id] ?? observation.text
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            fields[category.rawValue, default: []].append(trimmed)
        }
        for candidate in candidates {
            guard let annotation = pictoAnnotations[candidate.id],
                  annotation.hasUsableContent,
                  let category = annotation.category else { continue }
            let label = annotation.label.trimmingCharacters(in: .whitespacesAndNewlines)
            fields[category.rawValue, default: []].append(label)
            persistLearning(candidate: candidate, annotation: annotation, category: category)
        }
        let mergedFields: [String: String] = fields.mapValues { $0.joined(separator: "\n") }

        let status = UploadStatus(filename: filename, state: .inFlight)
        uploads.append(status)
        let statusID = status.id
        let referenceID = reference.id

        self.pending = nil
        observations = []
        assignments = [:]
        ocrEdits = [:]
        hiddenOCRIDs = []
        candidates = []
        pictoAnnotations = [:]
        analysisTask?.cancel()
        analysisTask = nil
        isRunningOCR = false
        isDetectingPictos = false

        Task { await runUpload(data: uploadData, filename: filename, statusID: statusID) }
        if !mergedFields.isEmpty, let referenceID {
            Task { await pushTechViews(referenceID: referenceID, fields: mergedFields) }
        }
    }

    /// Saves a new `LearnedPictogram` when the user labelled an
    /// unknown picto, or bumps the match counter on an existing one
    /// when they accepted a suggestion verbatim.
    private func persistLearning(
        candidate: TechViewsPictoDetection.Candidate,
        annotation: PictoAnnotation,
        category: TechViewCategory
    ) {
        // Reinforcement path: same learned picto, same label.
        if let matchedID = annotation.matchedLearnedID,
           let existing = learnedPictograms.first(where: { $0.persistentModelID == matchedID }),
           annotation.reinforces(existing) {
            existing.matchCount += 1
            return
        }
        // Otherwise teach a new picto. Resize the crop to a small
        // thumbnail before persisting — the embedding is what matters
        // for matching; the image is just for the UI.
        guard let thumbnailData = candidate.crop
            .resized(toMaxDimension: 200)
            .jpegData(compressionQuality: 0.7) else { return }
        let pictogram = LearnedPictogram(
            label: annotation.label.trimmingCharacters(in: .whitespacesAndNewlines),
            category: category,
            embedding: candidate.featurePrintData,
            thumbnailData: thumbnailData
        )
        modelContext.insert(pictogram)
    }

    @MainActor
    private func runUpload(data: Data, filename: String, statusID: UUID) async {
        do {
            let production = try await findOrCreateProduction()
            let upload = ProductionUploadService(environment: settings.currentEnvironment)
            try await upload.upload(
                jpegData: data,
                filename: filename,
                productionRootID: production.rootID
            )
            updateStatus(id: statusID, to: .succeeded)
        } catch let err as GSHTTPClient.HTTPError {
            updateStatus(id: statusID, to: .failed(err.userMessage))
        } catch {
            updateStatus(id: statusID, to: .failed(error.localizedDescription))
        }
    }

    @MainActor
    private func pushTechViews(referenceID: Int, fields: [String: String]) async {
        do {
            let service = ReferenceExtraService(environment: settings.currentEnvironment)
            try await service.updateTechViews(referenceID: referenceID, fields: fields)
        } catch {
            let message = (error as? GSHTTPClient.HTTPError)?.userMessage ?? error.localizedDescription
            print("[TechViews] updateTechViews failed: \(message)")
        }
    }

    @MainActor
    private func findOrCreateProduction() async throws -> Production {
        guard let shootingMethodID = settings.techViewsShootingMethodID else {
            throw GSHTTPClient.HTTPError.http(status: 400, body: "No shooting method configured.")
        }
        let service = ProductionService(environment: settings.currentEnvironment)
        return try await service.findOrCreateToday(shootingMethodID: shootingMethodID)
    }

    private func updateStatus(id: UUID, to state: UploadStatus.State) {
        guard let idx = uploads.firstIndex(where: { $0.id == id }) else { return }
        uploads[idx].state = state
    }
}

// MARK: - UIImage resize helper

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

    /// Returns a copy whose pixel buffer matches the display
    /// orientation (`imageOrientation == .up`). When the camera
    /// hands us a JPEG with EXIF orientation other than `.up` the
    /// raw `cgImage` is in sensor space — this redraw bakes the
    /// rotation into the pixels so downstream Vision + crop code
    /// can assume a single, consistent coordinate space.
    func normalizedUp() -> UIImage {
        guard imageOrientation != .up else { return self }
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

// MARK: - JPEG encoder that preserves EXIF

/// Encodes the resized `image` to JPEG while copying the source
/// camera JPEG's full property graph (EXIF / TIFF / GPS /
/// Maker-Note dictionaries). `UIImage.jpegData(compressionQuality:)`
/// drops metadata, so we go through Image I/O instead. Only
/// orientation (now `.up`) and pixel dimensions (now the resized
/// values) are overridden — focal length, white-balance mode,
/// ISO, lens make + model, GPS and Apple maker notes from the
/// camera flow through unchanged.
private func encodeJPEGPreservingMetadata(
    image: UIImage,
    sourceJPEG: Data,
    quality: CGFloat
) -> Data? {
    guard let cgImage = image.cgImage else { return nil }
    let outData = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        outData,
        UTType.jpeg.identifier as CFString,
        1,
        nil
    ) else { return nil }

    var properties: [String: Any] = [:]
    if let source = CGImageSourceCreateWithData(sourceJPEG as CFData, nil),
       let sourceProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {
        properties = sourceProperties
    }
    properties[kCGImagePropertyOrientation as String] = 1
    properties[kCGImagePropertyPixelWidth as String] = cgImage.width
    properties[kCGImagePropertyPixelHeight as String] = cgImage.height
    var tiff = (properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any]) ?? [:]
    tiff[kCGImagePropertyTIFFOrientation as String] = 1
    properties[kCGImagePropertyTIFFDictionary as String] = tiff
    var exif = (properties[kCGImagePropertyExifDictionary as String] as? [String: Any]) ?? [:]
    exif[kCGImagePropertyExifPixelXDimension as String] = cgImage.width
    exif[kCGImagePropertyExifPixelYDimension as String] = cgImage.height
    properties[kCGImagePropertyExifDictionary as String] = exif
    properties[kCGImageDestinationLossyCompressionQuality as String] = quality

    CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return outData as Data
}
