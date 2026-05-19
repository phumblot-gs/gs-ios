#if os(iOS)
import SwiftUI
@preconcurrency import ARKit
import RealityKit

/// `UIViewRepresentable` hosting an `ARView` with LiDAR scene
/// reconstruction enabled. The `controller` is a shared object the
/// SwiftUI parent uses to trigger a frame capture or inspect the
/// current session state.
struct ARLiveView: UIViewRepresentable {
    let controller: ARCaptureController

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero)
        controller.attach(arView: view)
        let config = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            config.sceneReconstruction = .meshWithClassification
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            config.frameSemantics.insert(.smoothedSceneDepth)
        } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        config.planeDetection = [.horizontal]
        view.session.run(config, options: [])
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        // Stateless — the controller drives interaction.
    }
}

/// Owns the active `ARView` reference and provides a thread-safe way to
/// snapshot the current frame.
@MainActor
final class ARCaptureController: ObservableObject {
    private weak var arView: ARView?
    private let ciContext = CIContext()

    func attach(arView: ARView) {
        self.arView = arView
    }

    /// Take the current ARFrame and convert it to a `CapturedFrame`. The
    /// AR session keeps running so the user can retake without delay.
    func captureFrame() -> CapturedFrame? {
        guard let frame = arView?.session.currentFrame else { return nil }

        let pixelBuffer = frame.capturedImage
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            // ARKit captures in landscape-right orientation regardless of
            // device rotation; rotate to portrait for downstream UI.
            .oriented(.right)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }
        let uiImage = UIImage(cgImage: cgImage)

        let depth = frame.smoothedSceneDepth?.depthMap ?? frame.sceneDepth?.depthMap

        return CapturedFrame(
            image: uiImage,
            depthMap: depth,
            cameraTransform: frame.camera.transform,
            cameraIntrinsics: frame.camera.intrinsics
        )
    }
}
#endif
