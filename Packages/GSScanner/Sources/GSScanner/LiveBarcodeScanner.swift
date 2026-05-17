#if os(iOS)
import UIKit
@preconcurrency import AVFoundation
import GSCore

/// Detected barcode passed back to SwiftUI.
public struct ScannedCode: Sendable, Hashable {
    public let payload: String
    public let symbology: ScannedSymbology
    public let detectedAt: Date

    public init(payload: String, symbology: ScannedSymbology, detectedAt: Date = .init()) {
        self.payload = payload
        self.symbology = symbology
        self.detectedAt = detectedAt
    }
}

/// UIKit controller that owns the AVCaptureSession, picks the best back
/// camera, attaches a metadata output, and renders detected barcodes via
/// a `ScannerOverlayView` sitting on top of the preview layer.
///
/// Public only because `LiveBarcodeScannerView` (a public
/// `UIViewControllerRepresentable`) has to surface it via its
/// `UIViewControllerType`. App code should drive it through the SwiftUI
/// view, not by instantiating the controller directly.
@MainActor
public final class LiveBarcodeScannerController: UIViewController {

    // MARK: - Public hooks (set by the SwiftUI representable)

    public var onScan: (@MainActor (ScannedCode) -> Void)?

    /// Re-fire `onScan` on the same payload only after this many seconds.
    public var cooldownSeconds: TimeInterval = 2.0

    public override init(nibName: String?, bundle: Bundle?) {
        super.init(nibName: nibName, bundle: bundle)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    // MARK: - Private state

    private let logger = GSLogger(category: "GSScanner")
    private let session = AVCaptureSession()
    private let metadataQueue = DispatchQueue(label: "com.grandshooting.gsmobile.scanner.metadata")

    private var previewLayer: AVCaptureVideoPreviewLayer!
    private let overlay = ScannerOverlayView()

    /// payload → last accepted time, used for the cooldown.
    private var recentlyAccepted: [String: Date] = [:]

    // MARK: - Lifecycle

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureSession()
        configurePreviewLayer()
        view.addSubview(overlay)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: view.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        Task.detached { [session] in
            if !session.isRunning {
                session.startRunning()
            }
        }
    }

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        Task.detached { [session] in
            if session.isRunning {
                session.stopRunning()
            }
        }
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    // MARK: - Session setup

    private func configureSession() {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .high

        guard let device = GSDeviceSupport.preferredBackCamera() else {
            logger.error("No back camera available")
            return
        }
        logger.info("Selected camera: \(device.localizedName)")
        configureFocus(on: device)

        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) {
                session.addInput(input)
            }
        } catch {
            logger.error("Failed to add camera input: \(error.localizedDescription)")
            return
        }

        let metadataOutput = AVCaptureMetadataOutput()
        if session.canAddOutput(metadataOutput) {
            session.addOutput(metadataOutput)
            metadataOutput.setMetadataObjectsDelegate(self, queue: metadataQueue)
            // Filter to the symbologies supported by AVMetadataOutput we care about.
            let supported = ScannedSymbology.allSupportedAVTypes
                .filter { metadataOutput.availableMetadataObjectTypes.contains($0) }
            metadataOutput.metadataObjectTypes = supported
        }
    }

    private func configureFocus(on device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            device.isSubjectAreaChangeMonitoringEnabled = true
            // Anchor focus at center of frame — that's where the crosshair is.
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5)
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = CGPoint(x: 0.5, y: 0.5)
            }
        } catch {
            logger.error("Failed to lock device for focus config: \(error.localizedDescription)")
        }
    }

    private func configurePreviewLayer() {
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.insertSublayer(layer, at: 0)
        previewLayer = layer
    }

    // MARK: - Center-picking

    /// Pick the metadata object whose bounding-box centre is nearest to the
    /// preview's centre. We map through `transformedMetadataObject` so all
    /// geometry is already in layer (view) coordinates.
    private func pickCenteredCode(
        from raw: [AVMetadataObject]
    ) -> (object: AVMetadataMachineReadableCodeObject, transformed: AVMetadataMachineReadableCodeObject)? {
        guard let previewLayer else { return nil }
        let center = CGPoint(x: previewLayer.bounds.midX, y: previewLayer.bounds.midY)

        var best: (AVMetadataMachineReadableCodeObject, AVMetadataMachineReadableCodeObject, CGFloat)? = nil
        for object in raw {
            guard let code = object as? AVMetadataMachineReadableCodeObject,
                  let transformed = previewLayer.transformedMetadataObject(for: code)
                    as? AVMetadataMachineReadableCodeObject else { continue }
            let center2 = CGPoint(x: transformed.bounds.midX, y: transformed.bounds.midY)
            let distance = hypot(center2.x - center.x, center2.y - center.y)
            if best == nil || distance < best!.2 {
                best = (code, transformed, distance)
            }
        }
        if let b = best {
            return (b.0, b.1)
        }
        return nil
    }
}

// MARK: - AVCaptureMetadataOutputObjectsDelegate

extension LiveBarcodeScannerController: AVCaptureMetadataOutputObjectsDelegate {
    public nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        // AVMetadataObject isn't Sendable, but the array we receive here is
        // owned by us once the delegate returns — AVFoundation doesn't reuse
        // it afterwards. Wrap in @unchecked Sendable so the strict checker
        // lets us hop to MainActor for UIKit / preview-layer work.
        let snapshot = UncheckedSendable(metadataObjects)
        Task { @MainActor [weak self] in
            self?.handle(snapshot.value)
        }
    }
}

/// `@unchecked Sendable` shim — used only inside this file to ferry
/// AVFoundation values across actor boundaries when we've reasoned about
/// the data-race risk locally.
private struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

private extension LiveBarcodeScannerController {
    func handle(_ metadataObjects: [AVMetadataObject]) {
        // 1. Build overlay highlights from every visible code.
        let highlights: [Highlight] = metadataObjects.compactMap { obj in
            guard let code = obj as? AVMetadataMachineReadableCodeObject,
                  let transformed = previewLayer?.transformedMetadataObject(for: code)
                    as? AVMetadataMachineReadableCodeObject,
                  let payload = transformed.stringValue ?? code.stringValue else { return nil }
            let cornerDicts = transformed.corners
            let corners = cornerDicts.map { CGPoint(x: $0.x, y: $0.y) }
            // AVMetadataMachineReadableCodeObject can return 0 corners on some
            // edge formats — skip those for overlay purposes.
            guard corners.count == 4 else { return nil }
            let symbology = ScannedSymbology(transformed.type)
            return Highlight(
                payload: payload,
                isOneDimensional: symbology.isOneDimensional,
                corners: corners
            )
        }
        overlay.updateHighlights(highlights)

        // 2. Pick the code closest to center for API dispatch.
        guard let (raw, transformed) = pickCenteredCode(from: metadataObjects),
              let payload = transformed.stringValue ?? raw.stringValue else { return }

        let now = Date()
        if let last = recentlyAccepted[payload],
           now.timeIntervalSince(last) < cooldownSeconds {
            return
        }
        recentlyAccepted[payload] = now

        let symbology = ScannedSymbology(transformed.type)
        let code = ScannedCode(payload: payload, symbology: symbology, detectedAt: now)
        onScan?(code)
    }
}
#endif
