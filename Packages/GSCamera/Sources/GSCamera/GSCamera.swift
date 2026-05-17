import SwiftUI
import AVFoundation
import GSCore

// MARK: - Configuration

public struct CameraConfig: Sendable {
    public var preferRAW: Bool
    public var maxPhotoQualityPrioritization: AVCapturePhotoOutput.QualityPrioritization

    public init(preferRAW: Bool = false,
                maxPhotoQualityPrioritization: AVCapturePhotoOutput.QualityPrioritization = .quality) {
        self.preferRAW = preferRAW
        self.maxPhotoQualityPrioritization = maxPhotoQualityPrioritization
    }
}

// MARK: - Result

public struct CapturedPhoto: Sendable {
    public let heifData: Data
    public let rawData: Data?
    public let capturedAt: Date

    public init(heifData: Data, rawData: Data? = nil, capturedAt: Date = .init()) {
        self.heifData = heifData
        self.rawData = rawData
        self.capturedAt = capturedAt
    }
}

// MARK: - SwiftUI view

/// SwiftUI placeholder camera surface. The real capture session wiring lives
/// inside `CameraSessionController` and will be filled out incrementally —
/// this stub exists so the rest of the app compiles and lays out correctly.
public struct CameraView: UIViewControllerRepresentable {
    private let config: CameraConfig
    private let onCapture: @MainActor (CapturedPhoto) -> Void

    public init(
        config: CameraConfig = CameraConfig(),
        onCapture: @escaping @MainActor (CapturedPhoto) -> Void
    ) {
        self.config = config
        self.onCapture = onCapture
    }

    public func makeUIViewController(context: Context) -> CameraSessionController {
        CameraSessionController(config: config, onCapture: onCapture)
    }

    public func updateUIViewController(_ controller: CameraSessionController, context: Context) {
        controller.update(config: config)
    }
}

// MARK: - UIViewController

/// Hosts the AVCaptureSession + preview layer. Currently a stub: it builds a
/// session, sets the quality prioritisation, and is ready to be extended with
/// preview layer + shutter UI.
public final class CameraSessionController: UIViewController {
    private let logger = GSLogger(category: "GSCamera")
    private var config: CameraConfig
    private let onCapture: @MainActor (CapturedPhoto) -> Void

    private let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()

    public init(config: CameraConfig, onCapture: @escaping @MainActor (CapturedPhoto) -> Void) {
        self.config = config
        self.onCapture = onCapture
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureSession()
    }

    func update(config: CameraConfig) {
        self.config = config
        photoOutput.maxPhotoQualityPrioritization = config.maxPhotoQualityPrioritization
    }

    private func configureSession() {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        }
        photoOutput.maxPhotoQualityPrioritization = config.maxPhotoQualityPrioritization
        // TODO: wire AVCaptureDevice + DeviceInput + preview layer + shutter button.
        logger.info("CameraSessionController configured (stub)")
    }
}
