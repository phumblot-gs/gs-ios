import SwiftUI
import GSCamera
import GSAPIClient

/// Camera step shown right after a stock_item is registered. The user
/// takes one photo of the product, reviews it, and saves — the JPEG is
/// resized to a 600×600 center-cropped square and uploaded to
/// `POST /reference/{id}/photo/upload`. A close (×) button skips the
/// step entirely; the stock_item is already saved either way.
struct ReceptionPhotoCaptureView: View {
    let settings: DevSettings
    let reference: Reference
    let onDone: @MainActor () -> Void

    @StateObject private var shutter = CameraShutter()
    @State private var pending: PendingShot?
    @State private var isUploading = false
    @State private var errorMessage: String?

    private struct PendingShot: Identifiable {
        let id = UUID()
        let image: UIImage
    }

    private var cameraConfiguration: CameraConfiguration {
        CameraConfiguration(
            mode: .presentation,
            whiteBalance: PresentationWhiteBalance(rawValue: settings.techViewsWhiteBalanceRaw) ?? .auto,
            colorProfile: PresentationColorProfile(rawValue: settings.techViewsColorProfileRaw) ?? .none,
            colorSpace: PresentationColorSpace(rawValue: settings.techViewsColorSpaceRaw) ?? .sRGB,
            targetFocalLength35mm: settings.techViewsPresentationFocal
        )
    }

    var body: some View {
        ZStack(alignment: .top) {
            CameraView(shutter: shutter, configuration: cameraConfiguration) { photo in
                handleCapture(photo: photo)
            }
            .ignoresSafeArea()

            topBar

            VStack {
                Spacer()
                if pending == nil {
                    shutterButton
                        .padding(.bottom, 32)
                }
            }

            if let pending {
                previewOverlay(for: pending)
            }
        }
    }

    // MARK: - Top bar (close + title)

    private var topBar: some View {
        HStack {
            Button {
                onDone()
            } label: {
                Image(systemName: "xmark")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(.black.opacity(0.5), in: Circle())
            }
            Spacer()
            VStack(spacing: 2) {
                Text("Reception photo")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text(reference.ref)
                    .font(.caption.monospaced())
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.black.opacity(0.5), in: Capsule())
            Spacer()
            // Symmetric spacer matching the close button so the title
            // stays centered.
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    // MARK: - Shutter

    private var shutterButton: some View {
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
    }

    // MARK: - Preview / confirmation overlay

    private func previewOverlay(for pending: PendingShot) -> some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer(minLength: 60)
                Image(uiImage: pending.image)
                    .resizable()
                    .scaledToFit()
                    .padding(.horizontal, 16)
                Spacer()
            }
            VStack(spacing: 10) {
                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.red.opacity(0.85), in: Capsule())
                }
                HStack(spacing: 16) {
                    Button {
                        retake()
                    } label: {
                        Label("Retake", systemImage: "arrow.uturn.backward")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .tint(.white)
                    .disabled(isUploading)

                    Button {
                        Task { await save(pending: pending) }
                    } label: {
                        HStack {
                            if isUploading { ProgressView().tint(.white) }
                            Label("Save", systemImage: "checkmark")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isUploading)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
    }

    // MARK: - Capture handling

    private func handleCapture(photo: CapturedPhoto) {
        guard let raw = UIImage(data: photo.imageData) else { return }
        pending = PendingShot(image: raw.normalizedUp())
        errorMessage = nil
    }

    private func retake() {
        pending = nil
        errorMessage = nil
    }

    private func save(pending: PendingShot) async {
        guard let referenceID = reference.id else {
            errorMessage = String(localized: "Reference is missing a reference_id.")
            return
        }
        // Center-crop to a square then resize to 600×600 — the GS
        // reception photo is meant to be a small thumbnail-grade asset.
        let squared = pending.image.centerCroppedSquare(side: 600)
        guard let data = squared.jpegData(compressionQuality: 0.8) else {
            errorMessage = String(localized: "Couldn't encode the photo.")
            return
        }

        isUploading = true
        defer { isUploading = false }

        let service = ReferencePhotoService(environment: settings.currentEnvironment)
        let filename = "\(reference.ref)_reception.jpg"
        do {
            try await service.uploadReceptionPhoto(
                referenceID: referenceID,
                jpegData: data,
                filename: filename
            )
            onDone()
        } catch let err as GSHTTPClient.HTTPError {
            errorMessage = err.userMessage
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private extension UIImage {
    /// Bakes any EXIF rotation into the pixel buffer so the cropped
    /// square actually matches what the user saw on the preview.
    func normalizedUp() -> UIImage {
        guard imageOrientation != .up else { return self }
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// Center-crops to a square then resizes to `side × side` px. Used
    /// for the low-res reception photo upload.
    func centerCroppedSquare(side: CGFloat) -> UIImage {
        let normalized = normalizedUp()
        let shorter = min(normalized.size.width, normalized.size.height)
        let offsetX = (normalized.size.width - shorter) / 2
        let offsetY = (normalized.size.height - shorter) / 2
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: side, height: side),
            format: format
        )
        let scale = side / shorter
        let drawSize = CGSize(
            width: normalized.size.width * scale,
            height: normalized.size.height * scale
        )
        let origin = CGPoint(x: -offsetX * scale, y: -offsetY * scale)
        return renderer.image { _ in
            normalized.draw(in: CGRect(origin: origin, size: drawSize))
        }
    }
}
