#if os(iOS)
import UIKit
import ARKit

/// Snapshot taken from an `ARSession` at the moment the user taps Capture.
/// Holds everything we need downstream to (a) detect subjects, (b) place
/// 3D points via raycast, and (c) keep the image rendered behind the
/// editor while AR continues tracking the scene.
struct CapturedFrame: Identifiable {
    let id = UUID()
    /// RGB image at capture time, already up-righted for portrait display.
    let image: UIImage
    /// Per-pixel depth in meters. Aligned to the captured image but at
    /// a lower resolution (typically 256x192 on iPhone Pro). Used in
    /// phase 4 to project 2D taps into 3D world coordinates.
    let depthMap: CVPixelBuffer?
    /// Camera transform at the moment of capture. We hold it so we can
    /// resolve the AR raycast back into the captured frame's coordinate
    /// space even if the device moves afterwards.
    let cameraTransform: simd_float4x4
    let cameraIntrinsics: simd_float3x3
    let capturedAt: Date

    init(
        image: UIImage,
        depthMap: CVPixelBuffer?,
        cameraTransform: simd_float4x4,
        cameraIntrinsics: simd_float3x3,
        capturedAt: Date = .init()
    ) {
        self.image = image
        self.depthMap = depthMap
        self.cameraTransform = cameraTransform
        self.cameraIntrinsics = cameraIntrinsics
        self.capturedAt = capturedAt
    }
}
#endif
