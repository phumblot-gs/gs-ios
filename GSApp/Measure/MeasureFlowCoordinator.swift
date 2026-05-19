#if os(iOS)
import SwiftUI
@preconcurrency import ARKit
import RealityKit
import AVFoundation
import simd
import UIKit

/// Single AR coordinator for the whole measure flow. Owns the ARView,
/// runs the world-tracking + scene-reconstruction session across every
/// step (capture → edit → pick category → place points → summary), and
/// exposes high-level operations used by SwiftUI:
///
/// - `captureFrame()` — snapshot the current AR frame as a still photo
///   (used during the capture step).
/// - `startReticle()` / `stopReticle()` — toggle live reticle tracking
///   during the placement step. While on, the coordinator publishes a
///   `reticleState` on each ARFrame, locks the point when the user
///   holds the device steady, and renders a 3D disc on the surface.
///
/// Keeping a single session alive matters: the world points captured at
/// placement time live in the same coordinate frame as
/// `CapturedFrame.cameraTransform`, so we can reproject them onto the
/// reference photo in the summary view.
@MainActor
final class MeasureFlowCoordinator: NSObject, ObservableObject {

    // MARK: - State exposed to SwiftUI

    /// Latest reticle update while tracking is active. Nil when not
    /// tracking, or when the depth raycast finds no valid surface.
    @Published private(set) var reticleState: ReticleState?

    /// Locked world points are pushed here for the placement view to
    /// consume. Reset between measurements.
    var onLock: ((SIMD3<Float>) -> Void)?

    struct ReticleState: Equatable {
        let worldPosition: SIMD3<Float>
        let stability: Float          // 0...1
    }

    // MARK: - Internals

    private weak var arView: ARView?
    private let ciContext = CIContext()
    private let stability = MeasureStabilityTracker()
    private var isTrackingReticle = false

    // The 3D disc rendered on the surface to confirm where the next
    // point will land. Anchored to the world; updated each frame.
    private var reticleAnchor: AnchorEntity?
    private var reticleDisc: ModelEntity?

    private let lockSoundID: SystemSoundID = 1113   // "Begin Recording"

    // MARK: - Lifecycle

    func attach(arView: ARView) {
        self.arView = arView
        arView.session.delegate = self
        arView.session.delegateQueue = .main
        installReticleEntity(in: arView)
    }

    // MARK: - Capture

    /// Take the current ARFrame and convert it to a `CapturedFrame`.
    func captureFrame() -> CapturedFrame? {
        guard let frame = arView?.session.currentFrame else { return nil }
        let pixelBuffer = frame.capturedImage
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer).oriented(.right)
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

    // MARK: - Reticle

    func startReticle() {
        isTrackingReticle = true
        stability.reset()
        reticleDisc?.isEnabled = true
    }

    func stopReticle() {
        isTrackingReticle = false
        reticleState = nil
        reticleDisc?.isEnabled = false
    }

    private func installReticleEntity(in arView: ARView) {
        let anchor = AnchorEntity(world: .zero)
        let disc = makeReticleDisc()
        anchor.addChild(disc)
        arView.scene.addAnchor(anchor)
        reticleAnchor = anchor
        reticleDisc = disc
        disc.isEnabled = false
    }

    private func makeReticleDisc() -> ModelEntity {
        // Thin disc lying in the XZ plane (Y is up in RealityKit). We
        // override its transform each frame to match the surface
        // normal.
        let radius: Float = 0.012   // 1.2 cm
        let mesh = MeshResource.generatePlane(width: radius * 2, depth: radius * 2, cornerRadius: radius)
        var material = UnlitMaterial(color: .white)
        material.color = .init(tint: UIColor.white.withAlphaComponent(0.85))
        let entity = ModelEntity(mesh: mesh, materials: [material])
        return entity
    }

    // MARK: - Per-frame processing

    fileprivate func handleFrame(_ frame: ARFrame) {
        guard isTrackingReticle, let arView else { return }
        guard let raw = projectScreenCenter(of: arView, in: frame) else {
            reticleState = nil
            reticleDisc?.isEnabled = false
            return
        }

        let (score, locked) = stability.observe(position: raw.world)
        let displayedPos = stability.averagedPosition ?? raw.world
        reticleState = ReticleState(worldPosition: displayedPos, stability: score)
        updateReticleTransform(world: displayedPos, normal: raw.normal)
        reticleDisc?.isEnabled = true

        if locked {
            AudioServicesPlaySystemSound(lockSoundID)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            onLock?(displayedPos)
        }
    }

    private func updateReticleTransform(world: SIMD3<Float>, normal: SIMD3<Float>) {
        guard let disc = reticleDisc else { return }
        // Build an orthonormal basis whose Y axis = surface normal.
        let n = simd_normalize(normal)
        // Pick an "up" reference that isn't collinear with n.
        let ref: SIMD3<Float> = abs(n.y) < 0.9 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)
        let xAxis = simd_normalize(simd_cross(ref, n))
        let zAxis = simd_normalize(simd_cross(n, xAxis))
        let basis = simd_float3x3(columns: (xAxis, n, zAxis))
        let rotation = simd_quatf(basis)
        disc.transform = Transform(scale: .one, rotation: rotation, translation: world)
    }

    /// Sample the depth at the screen center and project to world coords.
    /// Returns the world position and the surface normal estimated from
    /// neighboring depth samples.
    private func projectScreenCenter(of arView: ARView, in frame: ARFrame) -> (world: SIMD3<Float>, normal: SIMD3<Float>)? {
        let depthMap = frame.smoothedSceneDepth?.depthMap ?? frame.sceneDepth?.depthMap
        guard let depthMap else { return nil }
        let imageWidth = CVPixelBufferGetWidth(frame.capturedImage)
        let imageHeight = CVPixelBufferGetHeight(frame.capturedImage)
        // ARKit's `capturedImage` is in landscape-right; map the
        // **portrait** screen center (0.5, 0.5) back to the corresponding
        // depth-map coordinate. In landscape coords the screen center
        // remains the image center.
        let normalizedDepthPoint = CGPoint(x: 0.5, y: 0.5)
        guard let pCameraLocal = DepthRaycaster.project(
            normalizedPoint: normalizedDepthPoint,
            depthMap: depthMap,
            intrinsics: frame.camera.intrinsics,
            imageSize: CGSize(width: imageWidth, height: imageHeight)
        ) else { return nil }

        // Camera-local → world.
        let pWorld4 = frame.camera.transform * SIMD4<Float>(pCameraLocal, 1)
        let pWorld = SIMD3<Float>(pWorld4.x, pWorld4.y, pWorld4.z)

        // Surface normal: sample two nearby depth pixels and take the
        // cross product of the resulting 3D differences. Fall back to
        // "facing the camera" if the neighbors are invalid.
        let normalWorld = computeNormal(
            atCenter: pCameraLocal,
            depthMap: depthMap,
            intrinsics: frame.camera.intrinsics,
            imageSize: CGSize(width: imageWidth, height: imageHeight),
            cameraTransform: frame.camera.transform
        ) ?? -SIMD3<Float>(
            frame.camera.transform.columns.2.x,
            frame.camera.transform.columns.2.y,
            frame.camera.transform.columns.2.z
        )

        return (pWorld, normalWorld)
    }

    private func computeNormal(
        atCenter pCenter: SIMD3<Float>,
        depthMap: CVPixelBuffer,
        intrinsics: simd_float3x3,
        imageSize: CGSize,
        cameraTransform: simd_float4x4
    ) -> SIMD3<Float>? {
        let offset: CGFloat = 0.02
        guard let pRight = DepthRaycaster.project(
            normalizedPoint: CGPoint(x: 0.5 + offset, y: 0.5),
            depthMap: depthMap,
            intrinsics: intrinsics,
            imageSize: imageSize
        ), let pDown = DepthRaycaster.project(
            normalizedPoint: CGPoint(x: 0.5, y: 0.5 + offset),
            depthMap: depthMap,
            intrinsics: intrinsics,
            imageSize: imageSize
        ) else { return nil }

        // Normals in camera-local space; convert to world via the
        // camera transform's rotation (3×3 sub-matrix).
        let v1 = pRight - pCenter
        let v2 = pDown - pCenter
        let nCamera = simd_normalize(simd_cross(v1, v2))
        // Flip so the normal points away from the surface (toward the
        // camera): camera is at origin in camera-local, surface is in
        // +Z; the surface normal should have negative Z.
        let nCamFacing = nCamera.z > 0 ? -nCamera : nCamera

        let rotation = simd_float3x3(
            SIMD3<Float>(cameraTransform.columns.0.x, cameraTransform.columns.0.y, cameraTransform.columns.0.z),
            SIMD3<Float>(cameraTransform.columns.1.x, cameraTransform.columns.1.y, cameraTransform.columns.1.z),
            SIMD3<Float>(cameraTransform.columns.2.x, cameraTransform.columns.2.y, cameraTransform.columns.2.z)
        )
        return simd_normalize(rotation * nCamFacing)
    }
}

// MARK: - ARSessionDelegate

extension MeasureFlowCoordinator: ARSessionDelegate {
    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // delegateQueue = .main → we're already on the main actor; the
        // hop below is just to satisfy the Swift 6 isolation checker.
        MainActor.assumeIsolated {
            self.handleFrame(frame)
        }
    }
}
#endif
