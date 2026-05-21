import AVFoundation
import GSCore

// MARK: - Result

public struct CapturedPhoto: Sendable {
    public let imageData: Data
    public let capturedAt: Date

    public init(imageData: Data, capturedAt: Date = .init()) {
        self.imageData = imageData
        self.capturedAt = capturedAt
    }
}

// MARK: - SwiftUI view (iOS only)

#if os(iOS)
import SwiftUI
import UIKit

/// Imperative shutter handle the SwiftUI parent uses to trigger a
/// photo. Mirrors authorization + capture state so the parent can
/// disable buttons / show a spinner while a frame is being processed.
@MainActor
public final class CameraShutter: ObservableObject {
    public enum Authorization: Equatable { case unknown, authorized, denied }

    @Published public private(set) var authorization: Authorization = .unknown
    @Published public private(set) var isCapturing: Bool = false

    fileprivate weak var controller: CameraSessionController?

    public init() {}

    public func capture() {
        controller?.capturePhoto()
    }

    fileprivate func update(authorization: Authorization) {
        self.authorization = authorization
    }

    fileprivate func update(isCapturing: Bool) {
        self.isCapturing = isCapturing
    }
}

public struct CameraView: UIViewControllerRepresentable {
    private let shutter: CameraShutter
    private let onCapture: @MainActor (CapturedPhoto) -> Void

    public init(
        shutter: CameraShutter,
        onCapture: @escaping @MainActor (CapturedPhoto) -> Void
    ) {
        self.shutter = shutter
        self.onCapture = onCapture
    }

    public func makeUIViewController(context: Context) -> CameraSessionController {
        let controller = CameraSessionController(shutter: shutter, onCapture: onCapture)
        shutter.controller = controller
        return controller
    }

    public func updateUIViewController(_ controller: CameraSessionController, context: Context) {}
}

// MARK: - UIViewController

public final class CameraSessionController: UIViewController {
    private let logger = GSLogger(category: "GSCamera")
    private let onCapture: @MainActor (CapturedPhoto) -> Void
    private weak var shutter: CameraShutter?

    private let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "com.grand-shooting.camera.session")
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var captureDelegate: CaptureDelegate?

    fileprivate init(
        shutter: CameraShutter,
        onCapture: @escaping @MainActor (CapturedPhoto) -> Void
    ) {
        self.shutter = shutter
        self.onCapture = onCapture
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        installPreviewLayer()
        Task { await authorizeAndConfigure() }
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.session.isRunning {
                self.session.startRunning()
            }
        }
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sessionQueue.async { [weak self] in
            self?.session.stopRunning()
        }
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    private func installPreviewLayer() {
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        previewLayer = layer
    }

    @MainActor
    private func authorizeAndConfigure() async {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        let granted: Bool
        switch status {
        case .authorized:
            granted = true
        case .notDetermined:
            granted = await AVCaptureDevice.requestAccess(for: .video)
        default:
            granted = false
        }
        shutter?.update(authorization: granted ? .authorized : .denied)
        guard granted else {
            logger.error("Camera access denied")
            return
        }
        sessionQueue.async { [weak self] in
            self?.configureSession()
            self?.session.startRunning()
        }
    }

    private func configureSession() {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .photo

        guard let device = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: .back
        ) else {
            logger.error("No back wide-angle camera available")
            return
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                logger.error("Cannot add camera input")
                return
            }
            session.addInput(input)
        } catch {
            logger.error("Camera input init failed: \(error)")
            return
        }

        guard session.canAddOutput(photoOutput) else {
            logger.error("Cannot add photo output")
            return
        }
        session.addOutput(photoOutput)
        photoOutput.maxPhotoQualityPrioritization = .quality
        logger.info("Camera session ready")
    }

    fileprivate func capturePhoto() {
        Task { @MainActor in self.shutter?.update(isCapturing: true) }
        let settings = AVCapturePhotoSettings(format: [
            AVVideoCodecKey: AVVideoCodecType.jpeg
        ])
        settings.photoQualityPrioritization = .quality
        let delegate = CaptureDelegate { [weak self] result in
            guard let self else { return }
            Task { @MainActor in
                self.shutter?.update(isCapturing: false)
                if case .success(let photo) = result {
                    self.onCapture(photo)
                }
            }
        }
        captureDelegate = delegate
        sessionQueue.async { [weak self] in
            self?.photoOutput.capturePhoto(with: settings, delegate: delegate)
        }
    }
}

private final class CaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let completion: (Result<CapturedPhoto, Error>) -> Void

    init(completion: @escaping (Result<CapturedPhoto, Error>) -> Void) {
        self.completion = completion
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error {
            completion(.failure(error))
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            completion(.failure(NSError(
                domain: "GSCamera",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Couldn't materialize photo data"]
            )))
            return
        }
        completion(.success(CapturedPhoto(imageData: data)))
    }
}
#endif
