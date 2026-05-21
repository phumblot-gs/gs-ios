import SwiftUI
import GSCamera
import GSAPIClient
import GSCore
import UIKit

/// Capture loop for a single reference. Live camera preview with a
/// shutter button; tapping it freezes the latest frame on top of the
/// preview so the user can decide Keep / Retake. Keep resizes the
/// JPEG to ≤ 1200 px on the long side and uploads it under the
/// filename `<ref>_<inc>.jpg` to today's production. The inc counter
/// resets to 1 each time the user enters this view (per session).
struct TechViewsCaptureView: View {
    @Bindable var settings: DevSettings
    let reference: Reference
    let onExit: @MainActor () -> Void

    @StateObject private var shutter = CameraShutter()
    @State private var pending: PendingShot?
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
                previewOverlay(pending)
            }
        }
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

    // MARK: - Preview overlay

    private func previewOverlay(_ pending: PendingShot) -> some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()
            Image(uiImage: pending.image)
                .resizable()
                .scaledToFit()
                .ignoresSafeArea(edges: [.leading, .trailing])

            VStack(spacing: 12) {
                Spacer()
                HStack(spacing: 16) {
                    Button(role: .cancel) {
                        self.pending = nil
                    } label: {
                        Label("Retake", systemImage: "arrow.counterclockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)

                    Button {
                        keep(pending: pending)
                    } label: {
                        Label("Keep", systemImage: "checkmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .controlSize(.large)
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
    }

    // MARK: - Actions

    private func handleCapture(photo: CapturedPhoto) {
        guard let image = UIImage(data: photo.imageData) else { return }
        pending = PendingShot(image: image, jpegData: photo.imageData)
    }

    private func keep(pending: PendingShot) {
        let inc = nextInc
        nextInc += 1
        let filename = "\(reference.ref)_\(inc).jpg"
        let resized = pending.image.resized(toMaxDimension: 1200)
        guard let uploadData = resized.jpegData(compressionQuality: 0.85) else {
            self.pending = nil
            return
        }
        let status = UploadStatus(filename: filename, state: .inFlight)
        uploads.append(status)
        let statusID = status.id
        self.pending = nil
        Task { await runUpload(data: uploadData, filename: filename, statusID: statusID) }
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
    /// Returns a copy bounded by `maxDimension` on the long side, with
    /// aspect ratio preserved. Renders via UIGraphicsImageRenderer so
    /// the output stays in the device-display colour space.
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
