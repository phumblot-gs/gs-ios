import SwiftUI
import ARKit
import RealityKit
import GSCore

/// Result of a LiDAR scan session.
public struct LiDARScanResult: Sendable {
    public let measurement: Measurement
    public let meshAnchors: Int

    public init(measurement: Measurement, meshAnchors: Int) {
        self.measurement = measurement
        self.meshAnchors = meshAnchors
    }
}

/// SwiftUI view that hosts an `ARView` configured for LiDAR scene
/// reconstruction with classification. Hardware-gated: caller should verify
/// `ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)`.
public struct LiDARScanView: UIViewRepresentable {
    private let onComplete: @MainActor (LiDARScanResult) -> Void

    public init(onComplete: @escaping @MainActor (LiDARScanResult) -> Void) {
        self.onComplete = onComplete
    }

    public func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        let config = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            config.sceneReconstruction = .meshWithClassification
        }
        config.frameSemantics.insert(.smoothedSceneDepth)
        arView.session.run(config, options: [])
        arView.debugOptions.insert(.showSceneUnderstanding)
        return arView
    }

    public func updateUIView(_ uiView: ARView, context: Context) {
        // no-op
    }
}

// MARK: - Object Capture (PhotogrammetrySession)

/// Wrapper around `PhotogrammetrySession` (Object Capture) for turning a folder
/// of photos into a textured mesh. This is a stub — full session wiring will
/// land alongside the capture-flow UI.
public struct ObjectCapturePhotogrammetry: Sendable {
    private let logger = GSLogger(category: "GSLiDAR.Photogrammetry")

    public init() {}

    /// Run photogrammetry on a folder of input photos and write the resulting
    /// model to `outputURL`. Stub: prints to log and returns immediately.
    public func process(inputFolder: URL, outputURL: URL) async throws {
        // TODO: implement using `PhotogrammetrySession(input: .folder(inputFolder))`
        //       streaming `.output` events until `.processingComplete`.
        logger.info("PhotogrammetrySession stub — input: \(inputFolder.path), output: \(outputURL.path)")
    }
}
