#if os(iOS)
import SwiftUI
@preconcurrency import ARKit
import RealityKit

/// `UIViewRepresentable` hosting an `ARView` with LiDAR scene
/// reconstruction enabled. The session is run with world tracking +
/// scene reconstruction + smoothed scene depth and stays alive for the
/// whole measure flow so world coordinates remain consistent between
/// the reference photo capture and the placement step.
struct ARLiveView: UIViewRepresentable {
    let coordinator: MeasureFlowCoordinator

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        let config = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            config.sceneReconstruction = .meshWithClassification
        } else if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            config.frameSemantics.insert(.smoothedSceneDepth)
        } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        config.planeDetection = [.horizontal]
        view.session.run(config, options: [])
        coordinator.attach(arView: view)
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        // Stateless — the coordinator drives interaction.
    }
}
#endif
