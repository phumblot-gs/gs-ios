@preconcurrency import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
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

// MARK: - Capture mode

/// Three operating modes the photo capture surface exposes:
/// `.presentation` for showroom-style shots (wide-angle, accurate
/// framing & colours), `.detail` for close-range product shots
/// that still want presentation's colour treatment (ultra-wide so
/// the lens focuses down to ~2 cm, but custom white balance and
/// colour profile still apply), and `.ocr` for label / packaging
/// reads (ultra-wide, auto white balance, no colour grading — the
/// caller only triggers Vision OCR + picto detection in this mode).
public enum CaptureMode: String, Sendable, CaseIterable, Identifiable {
    case presentation
    case detail
    case ocr

    public var id: String { rawValue }

    /// True when the mode is meant for product photos — i.e. the
    /// caller should apply the user's WB and colour profile to the
    /// output JPEG. Always false for `.ocr`.
    public var honoursPresentationProcessing: Bool {
        switch self {
        case .presentation, .detail: true
        case .ocr: false
        }
    }
}

/// Optional colour-grading hint applied to `.presentation` shots
/// after capture. Keeps `.none` as default; the curated values
/// loosely approximate the look produced by various phone vendors'
/// in-camera ISP pipelines.
public enum PresentationColorProfile: String, Sendable, CaseIterable, Identifiable, Codable {
    case none
    case neutral
    case appleLike
    case samsungLike
    case pixelLike
    case studio

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .none: "None"
        case .neutral: "Neutral"
        case .appleLike: "Apple-like"
        case .samsungLike: "Samsung-like"
        case .pixelLike: "Pixel-like"
        case .studio: "Studio (flat)"
        }
    }

    public var summary: String {
        switch self {
        case .none: "No post-processing applied to the JPEG."
        case .neutral: "Gentle contrast and saturation lift for everyday shots."
        case .appleLike: "Cooler tint, mild saturation boost — mimics iPhone defaults."
        case .samsungLike: "Warmer tint with stronger saturation — mimics Samsung Galaxy defaults."
        case .pixelLike: "High contrast, neutral white balance — mimics Google Pixel."
        case .studio: "Flat, low-saturation look intended for downstream colour grading."
        }
    }
}

/// White-balance behaviour for the `.presentation` capture mode.
/// `.auto` is iOS continuous WB; the explicit temperatures lock the
/// device to a fixed colour temperature (degrees Kelvin) so multiple
/// shots of the same product look identical.
public enum PresentationWhiteBalance: String, Sendable, CaseIterable, Identifiable, Codable {
    case auto
    case tungsten2700K
    case warmFluo3500K
    case daylight5500K
    case cloudy6500K
    case shade7500K

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .auto: "Auto"
        case .tungsten2700K: "Tungsten (2700 K)"
        case .warmFluo3500K: "Warm fluorescent (3500 K)"
        case .daylight5500K: "Daylight (5500 K)"
        case .cloudy6500K: "Cloudy (6500 K)"
        case .shade7500K: "Shade (7500 K)"
        }
    }

    public var temperature: Float? {
        switch self {
        case .auto: nil
        case .tungsten2700K: 2700
        case .warmFluo3500K: 3500
        case .daylight5500K: 5500
        case .cloudy6500K: 6500
        case .shade7500K: 7500
        }
    }
}

/// Static configuration knobs the caller passes into `CameraView`.
/// We avoid making these `@Published` so changing them between
/// captures doesn't trigger SwiftUI churn — callers re-create the
/// view (or call `CameraShutter.applySettings`) on real changes.
public struct CameraConfiguration: Sendable {
    public var mode: CaptureMode
    public var whiteBalance: PresentationWhiteBalance
    public var colorProfile: PresentationColorProfile

    public init(
        mode: CaptureMode = .presentation,
        whiteBalance: PresentationWhiteBalance = .auto,
        colorProfile: PresentationColorProfile = .none
    ) {
        self.mode = mode
        self.whiteBalance = whiteBalance
        self.colorProfile = colorProfile
    }
}

public struct CameraCapabilities: Sendable {
    public var hasUltraWide: Bool
    public init(hasUltraWide: Bool = false) {
        self.hasUltraWide = hasUltraWide
    }
}

// MARK: - SwiftUI view (iOS only)

#if os(iOS)
import SwiftUI
import UIKit

/// Imperative shutter handle the SwiftUI parent uses to trigger a
/// photo. Mirrors authorization + capture state and the active
/// capture mode so the parent can disable buttons, show a spinner,
/// or update its toggle icon.
@MainActor
public final class CameraShutter: ObservableObject {
    public enum Authorization: Equatable { case unknown, authorized, denied }

    @Published public private(set) var authorization: Authorization = .unknown
    @Published public private(set) var isCapturing: Bool = false
    @Published public private(set) var mode: CaptureMode = .presentation
    @Published public private(set) var capabilities: CameraCapabilities = .init()

    fileprivate var configuration: CameraConfiguration = .init()
    fileprivate weak var controller: CameraSessionController?

    public init() {}

    public func capture() {
        controller?.capturePhoto()
    }

    public func switchMode(to newMode: CaptureMode) {
        guard newMode != mode else { return }
        mode = newMode
        configuration.mode = newMode
        controller?.apply(configuration: configuration)
    }

    /// Replace the full configuration (mode, WB, colour profile)
    /// — useful when Settings change while the camera view is
    /// already on screen. Defers the `@Published` mutation off the
    /// caller's frame so we don't trip SwiftUI's "publishing
    /// changes from within view updates" warning when callers
    /// invoke this from a view body / `onChange` handler.
    public func applySettings(_ configuration: CameraConfiguration) {
        self.configuration = configuration
        let newMode = configuration.mode
        let pendingConfiguration = configuration
        Task { @MainActor [weak self] in
            self?.mode = newMode
            self?.controller?.apply(configuration: pendingConfiguration)
        }
    }

    // Wiring used by the controller.
    fileprivate func update(authorization: Authorization) {
        self.authorization = authorization
    }
    fileprivate func update(isCapturing: Bool) {
        self.isCapturing = isCapturing
    }
    fileprivate func update(capabilities: CameraCapabilities) {
        self.capabilities = capabilities
    }
    /// Called from `CameraView.makeUIViewController`, i.e. during a
    /// SwiftUI view update. The `@Published` `mode` mutation must
    /// be deferred so we don't run inside the same frame that
    /// triggered the view make.
    fileprivate func seedInitial(configuration: CameraConfiguration) {
        self.configuration = configuration
        let newMode = configuration.mode
        Task { @MainActor [weak self] in
            self?.mode = newMode
        }
    }
}

public struct CameraView: UIViewControllerRepresentable {
    private let shutter: CameraShutter
    private let configuration: CameraConfiguration
    private let onCapture: @MainActor (CapturedPhoto) -> Void

    public init(
        shutter: CameraShutter,
        configuration: CameraConfiguration = .init(),
        onCapture: @escaping @MainActor (CapturedPhoto) -> Void
    ) {
        self.shutter = shutter
        self.configuration = configuration
        self.onCapture = onCapture
    }

    public func makeUIViewController(context: Context) -> CameraSessionController {
        shutter.seedInitial(configuration: configuration)
        let controller = CameraSessionController(
            shutter: shutter,
            configuration: configuration,
            onCapture: onCapture
        )
        shutter.controller = controller
        return controller
    }

    public func updateUIViewController(_ controller: CameraSessionController, context: Context) {}
}

// MARK: - UIViewController

public final class CameraSessionController: UIViewController {
    // AVCaptureSession / AVCapturePhotoOutput / AVCaptureDeviceInput
    // are touched exclusively from `sessionQueue`, which is a serial
    // dispatch queue dedicated to capture work. They can't live as
    // MainActor-isolated state without forcing every closure into a
    // hop. Opting them out of actor isolation here lets the queue
    // serialise access on our behalf.
    nonisolated(unsafe) private let session = AVCaptureSession()
    nonisolated(unsafe) private let photoOutput = AVCapturePhotoOutput()
    nonisolated(unsafe) private var captureDelegate: CaptureDelegate?
    nonisolated(unsafe) private var activeInput: AVCaptureDeviceInput?

    private let logger = GSLogger(category: "GSCamera")
    private let onCapture: @MainActor (CapturedPhoto) -> Void
    private weak var shutter: CameraShutter?
    private let sessionQueue = DispatchQueue(label: "com.grand-shooting.camera.session")
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var configuration: CameraConfiguration
    /// Tracks the device's physical orientation via the
    /// accelerometer + preview layer so the preview and the
    /// captured JPEG both end up "level with the horizon" — i.e.
    /// the photo matches what the user saw when they pressed the
    /// shutter regardless of how they were holding the phone.
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?

    fileprivate init(
        shutter: CameraShutter,
        configuration: CameraConfiguration,
        onCapture: @escaping @MainActor (CapturedPhoto) -> Void
    ) {
        self.shutter = shutter
        self.configuration = configuration
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
        let capabilities = CameraCapabilities(hasUltraWide: Self.detectUltraWide())
        shutter?.update(capabilities: capabilities)
        let snapshot = configuration
        if let device = Self.preferredDevice(for: snapshot.mode) {
            installRotationCoordinator(for: device)
        }
        sessionQueue.async { [weak self] in
            self?.configureSession(with: snapshot)
            self?.session.startRunning()
        }
    }

    /// Spins up an `AVCaptureDevice.RotationCoordinator` for the
    /// given device and immediately applies the live preview angle
    /// so the live feed sits horizon-level. KVO on the preview
    /// angle keeps things lined up if the user physically rotates
    /// the phone while a session is active.
    @MainActor
    private func installRotationCoordinator(for device: AVCaptureDevice) {
        rotationObservation?.invalidate()
        rotationObservation = nil
        let coordinator = AVCaptureDevice.RotationCoordinator(
            device: device,
            previewLayer: previewLayer
        )
        rotationCoordinator = coordinator
        applyPreviewRotation()
        rotationObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelPreview,
            options: [.new]
        ) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.applyPreviewRotation()
            }
        }
    }

    @MainActor
    private func applyPreviewRotation() {
        guard
            let coordinator = rotationCoordinator,
            let connection = previewLayer?.connection
        else { return }
        let angle = coordinator.videoRotationAngleForHorizonLevelPreview
        if connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
    }

    nonisolated private static func detectUltraWide() -> Bool {
        AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) != nil
    }

    nonisolated private func configureSession(with configuration: CameraConfiguration) {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .photo

        guard let device = Self.preferredDevice(for: configuration.mode) else {
            logger.error("No back camera available")
            return
        }
        guard let input = Self.attachInput(for: device, to: session, logger: logger) else {
            return
        }
        activeInput = input
        Self.configureDevice(device, for: configuration, logger: logger)

        guard session.canAddOutput(photoOutput) else {
            logger.error("Cannot add photo output")
            return
        }
        session.addOutput(photoOutput)
        photoOutput.maxPhotoQualityPrioritization = .quality
        logger.info("Camera session ready in \(configuration.mode.rawValue) mode")
    }

    /// Reconfigure the session for a new capture configuration —
    /// typically a mode flip or a settings change. Swaps the input
    /// device when needed and re-applies focus / exposure / WB so
    /// the new behaviour takes effect on the next frame.
    fileprivate func apply(configuration: CameraConfiguration) {
        self.configuration = configuration
        let snapshot = configuration
        if let device = Self.preferredDevice(for: snapshot.mode) {
            installRotationCoordinator(for: device)
        }
        sessionQueue.async { [weak self] in
            self?.reconfigure(with: snapshot)
        }
    }

    nonisolated private func reconfigure(with configuration: CameraConfiguration) {
        let oldDeviceType = activeInput?.device.deviceType
        let newDevice = Self.preferredDevice(for: configuration.mode)
        let needsSwap = oldDeviceType != newDevice?.deviceType
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if needsSwap, let newDevice {
            if let existing = activeInput {
                session.removeInput(existing)
                activeInput = nil
            }
            if let input = Self.attachInput(for: newDevice, to: session, logger: logger) {
                activeInput = input
            }
            Self.configureDevice(newDevice, for: configuration, logger: logger)
        } else if let device = activeInput?.device {
            Self.configureDevice(device, for: configuration, logger: logger)
        }
    }

    nonisolated private static func preferredDevice(for mode: CaptureMode) -> AVCaptureDevice? {
        switch mode {
        case .presentation:
            return AVCaptureDevice.default(
                .builtInWideAngleCamera,
                for: .video,
                position: .back
            )
        case .detail, .ocr:
            // Both detail and OCR want the close-focus capability
            // of the ultra-wide sensor; fall back to wide-angle on
            // devices where the ultra-wide isn't present.
            if let ultra = AVCaptureDevice.default(
                .builtInUltraWideCamera,
                for: .video,
                position: .back
            ) {
                return ultra
            }
            return AVCaptureDevice.default(
                .builtInWideAngleCamera,
                for: .video,
                position: .back
            )
        }
    }

    nonisolated private static func attachInput(
        for device: AVCaptureDevice,
        to session: AVCaptureSession,
        logger: GSLogger
    ) -> AVCaptureDeviceInput? {
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                logger.error("Cannot add camera input for \(device.localizedName)")
                return nil
            }
            session.addInput(input)
            return input
        } catch {
            logger.error("Camera input init failed: \(error)")
            return nil
        }
    }

    nonisolated private static func configureDevice(
        _ device: AVCaptureDevice,
        for configuration: CameraConfiguration,
        logger: GSLogger
    ) {
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            switch configuration.mode {
            case .presentation, .detail:
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                }
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
                Self.applyWhiteBalance(configuration.whiteBalance, on: device)

            case .ocr:
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5)
                }
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = CGPoint(x: 0.5, y: 0.5)
                }
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
                // OCR always auto-WB — readability over consistency.
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    device.whiteBalanceMode = .continuousAutoWhiteBalance
                }
            }
        } catch {
            logger.error("Device configuration failed: \(error)")
        }
    }

    nonisolated private static func applyWhiteBalance(
        _ wb: PresentationWhiteBalance,
        on device: AVCaptureDevice
    ) {
        if let temperature = wb.temperature,
           device.isLockingWhiteBalanceWithCustomDeviceGainsSupported {
            let tempTint = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
                temperature: temperature,
                tint: 0
            )
            let rawGains = device.deviceWhiteBalanceGains(for: tempTint)
            let gains = normalisedGains(rawGains, on: device)
            device.setWhiteBalanceModeLocked(with: gains)
        } else if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            device.whiteBalanceMode = .continuousAutoWhiteBalance
        }
    }

    /// `setWhiteBalanceModeLockedWithDeviceWhiteBalanceGains`
    /// requires each channel to be ≥ 1 and ≤ `maxWhiteBalanceGain`.
    /// Clamp so a far-end temperature doesn't trip the assertion.
    nonisolated private static func normalisedGains(
        _ gains: AVCaptureDevice.WhiteBalanceGains,
        on device: AVCaptureDevice
    ) -> AVCaptureDevice.WhiteBalanceGains {
        let maxGain = device.maxWhiteBalanceGain
        return AVCaptureDevice.WhiteBalanceGains(
            redGain: min(max(gains.redGain, 1), maxGain),
            greenGain: min(max(gains.greenGain, 1), maxGain),
            blueGain: min(max(gains.blueGain, 1), maxGain)
        )
    }

    fileprivate func capturePhoto() {
        Task { @MainActor in self.shutter?.update(isCapturing: true) }
        let modeForCapture = configuration.mode
        let profileForCapture = configuration.colorProfile
        // Read the live capture angle from the rotation coordinator
        // *now*, on the main actor, so the value matches whatever
        // orientation the user is holding the phone at the moment
        // they tapped the shutter. We then pass that scalar into
        // the session queue closure for the actual capture call.
        let captureAngle: CGFloat = rotationCoordinator?
            .videoRotationAngleForHorizonLevelCapture ?? 90
        let delegate = CaptureDelegate { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                Task { @MainActor in self.shutter?.update(isCapturing: false) }
            case .success(let raw):
                Task.detached(priority: .userInitiated) {
                    let processed = ColorProfileProcessor.apply(
                        profileForCapture,
                        to: raw,
                        when: modeForCapture
                    )
                    await MainActor.run {
                        self.shutter?.update(isCapturing: false)
                        self.onCapture(processed)
                    }
                }
            }
        }
        captureDelegate = delegate
        sessionQueue.async { [weak self] in
            // Build the settings inside the queue so we don't cross
            // an actor boundary with a non-Sendable
            // `AVCapturePhotoSettings`.
            let settings = AVCapturePhotoSettings(format: [
                AVVideoCodecKey: AVVideoCodecType.jpeg
            ])
            settings.photoQualityPrioritization = .quality
            // Apply the rotation read from the RotationCoordinator
            // right before triggering the capture. Set per-capture
            // (rather than once at session setup) because device
            // swaps — Presentation ↔ Detail ↔ OCR — re-create the
            // connection.
            if let connection = self?.photoOutput.connection(with: .video),
               connection.isVideoRotationAngleSupported(captureAngle) {
                connection.videoRotationAngle = captureAngle
            }
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

// MARK: - Colour-profile post-processing

private enum ColorProfileProcessor {

    /// Apply a colour profile to a JPEG. We only post-process
    /// modes that honour presentation processing (presentation +
    /// detail) — OCR captures are returned untouched since
    /// readability beats prettiness there. `.none` skips the
    /// CoreImage round-trip entirely.
    static func apply(
        _ profile: PresentationColorProfile,
        to photo: CapturedPhoto,
        when mode: CaptureMode
    ) -> CapturedPhoto {
        guard mode.honoursPresentationProcessing, profile != .none else { return photo }
        guard let result = graded(jpegData: photo.imageData, profile: profile) else {
            return photo
        }
        return CapturedPhoto(imageData: result, capturedAt: photo.capturedAt)
    }

    private static func graded(jpegData: Data, profile: PresentationColorProfile) -> Data? {
        // Going through UIImage(data:) → CIImage(image:) bakes the
        // source's EXIF orientation into the pixel buffer up front,
        // so the graded JPEG comes out in display-oriented pixels
        // with EXIF orientation = .up. Downstream consumers (OCR,
        // crop preview) get the same self-consistent pixel space
        // they expect from a raw camera capture.
        guard let uiSource = UIImage(data: jpegData),
              let ciSource = CIImage(image: uiSource) else { return nil }
        let graded = apply(profile: profile, to: ciSource)
        let context = CIContext()
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let cgImage = context.createCGImage(
            graded,
            from: graded.extent,
            format: .RGBA8,
            colorSpace: colorSpace
        ) else { return nil }
        return UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.92)
    }

    private static func apply(profile: PresentationColorProfile, to image: CIImage) -> CIImage {
        switch profile {
        case .none:
            return image
        case .neutral:
            return colorControls(image, saturation: 1.08, contrast: 1.04, brightness: 0)
        case .appleLike:
            // Slight cool tint + saturation boost.
            let toned = temperatureAndTint(image, neutral: 5500, target: 5200)
            return colorControls(toned, saturation: 1.18, contrast: 1.05, brightness: 0)
        case .samsungLike:
            // Warmer, stronger saturation.
            let toned = temperatureAndTint(image, neutral: 5500, target: 6000)
            return colorControls(toned, saturation: 1.32, contrast: 1.08, brightness: 0.02)
        case .pixelLike:
            // High contrast, neutral WB.
            return colorControls(image, saturation: 1.05, contrast: 1.15, brightness: -0.02)
        case .studio:
            // Flat, low saturation — good for downstream grading.
            return colorControls(image, saturation: 0.82, contrast: 0.95, brightness: 0.01)
        }
    }

    private static func colorControls(
        _ image: CIImage,
        saturation: Float,
        contrast: Float,
        brightness: Float
    ) -> CIImage {
        let filter = CIFilter.colorControls()
        filter.inputImage = image
        filter.saturation = saturation
        filter.contrast = contrast
        filter.brightness = brightness
        return filter.outputImage ?? image
    }

    private static func temperatureAndTint(
        _ image: CIImage,
        neutral: Float,
        target: Float
    ) -> CIImage {
        let filter = CIFilter.temperatureAndTint()
        filter.inputImage = image
        filter.neutral = CIVector(x: CGFloat(neutral), y: 0)
        filter.targetNeutral = CIVector(x: CGFloat(target), y: 0)
        return filter.outputImage ?? image
    }
}

#endif
