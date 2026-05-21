import SwiftUI
import GSCamera
import GSAPIClient
import GSCore
import UIKit

/// Capture loop for a single reference. Live camera preview with a
/// shutter; after each shot Vision runs OCR on the still in the
/// background while the user reviews the result on the annotation
/// sheet. The user tags any extracted text with one of six tech-view
/// categories, then taps "Save" — the photo uploads to today's
/// production under `<ref>_<inc>.jpg`, and the categorised text is
/// pushed to `extra.tech_views` on the reference. Both calls fire
/// in parallel and don't block the next shot.
struct TechViewsCaptureView: View {
    @Bindable var settings: DevSettings
    let reference: Reference
    let onExit: @MainActor () -> Void

    @StateObject private var shutter = CameraShutter()
    @State private var pending: PendingShot?
    @State private var observations: [OCRObservation] = []
    @State private var assignments: [UUID: TechViewCategory] = [:]
    @State private var isRunningOCR: Bool = false
    @State private var ocrTask: Task<Void, Never>?
    @State private var nextInc: Int = 1
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

    var body: some View {
        ZStack {
            CameraView(shutter: shutter) { photo in
                handleCapture(photo: photo)
            }
            .ignoresSafeArea()

            VStack {
                topBar
                Spacer()
                if pending == nil {
                    bottomControls
                }
            }

            if let pending {
                TechViewsAnnotationView(
                    image: pending.image,
                    observations: observations,
                    isRunningOCR: isRunningOCR,
                    assignments: $assignments,
                    onRetake: { retake() },
                    onSave: { save(pending: pending) }
                )
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: pending?.id)
        .navigationBarBackButtonHidden()
        .navigationBarTitleDisplayMode(.inline)
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
            HStack {
                Spacer()
                Button {
                    shutter.capture()
                } label: {
                    ZStack {
                        Circle().fill(.white).frame(width: 76, height: 76)
                        Circle().stroke(.white, lineWidth: 4).frame(width: 88, height: 88)
                    }
                }
                .disabled(shutter.isCapturing || shutter.authorization != .authorized)
                .accessibilityLabel("Shutter")
                Spacer()
            }
            .padding(.bottom, 32)
        }
    }

    // MARK: - Actions

    private func handleCapture(photo: CapturedPhoto) {
        guard let image = UIImage(data: photo.imageData) else { return }
        observations = []
        assignments = [:]
        pending = PendingShot(image: image, jpegData: photo.imageData)
        isRunningOCR = true
        ocrTask?.cancel()
        ocrTask = Task {
            do {
                let result = try await TechViewsOCR.recognize(in: image)
                if Task.isCancelled { return }
                await MainActor.run {
                    observations = result
                    isRunningOCR = false
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    observations = []
                    isRunningOCR = false
                }
            }
        }
    }

    private func retake() {
        ocrTask?.cancel()
        ocrTask = nil
        pending = nil
        observations = []
        assignments = [:]
        isRunningOCR = false
    }

    private func save(pending: PendingShot) {
        // Snapshot the data the upload tasks need before we reset
        // the pending state — Swift's @State setters are async, and
        // the UI dismissal shouldn't race the background tasks.
        let inc = nextInc
        nextInc += 1
        let filename = "\(reference.ref)_\(inc).jpg"
        let resized = pending.image.resized(toMaxDimension: 1200)
        guard let uploadData = resized.jpegData(compressionQuality: 0.85) else {
            self.pending = nil
            observations = []
            assignments = [:]
            return
        }

        // Aggregate categorised text per category (newline-separated
        // when several observations land in the same bucket).
        var fields: [String: String] = [:]
        for observation in observations {
            guard let category = assignments[observation.id] else { continue }
            let trimmed = observation.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = category.rawValue
            if let existing = fields[key], !existing.isEmpty {
                fields[key] = existing + "\n" + trimmed
            } else {
                fields[key] = trimmed
            }
        }

        let status = UploadStatus(filename: filename, state: .inFlight)
        uploads.append(status)
        let statusID = status.id
        let referenceID = reference.id

        self.pending = nil
        observations = []
        assignments = [:]
        ocrTask?.cancel()
        ocrTask = nil
        isRunningOCR = false

        Task { await runUpload(data: uploadData, filename: filename, statusID: statusID) }
        if !fields.isEmpty, let referenceID {
            Task { await pushTechViews(referenceID: referenceID, fields: fields) }
        }
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
            // Non-blocking: failure to push categorised text doesn't
            // affect the photo upload. We surface it through the
            // existing per-upload error banner instead of a dedicated
            // channel since the photo + extra usually go together.
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
}
