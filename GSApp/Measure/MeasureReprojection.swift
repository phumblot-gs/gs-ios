#if os(iOS)
import Foundation
import CoreGraphics
import simd

/// Projects a 3D world point (in the same ARKit world coordinate system
/// the `CapturedFrame` was captured in) back onto the portrait image
/// used as the reference photo. Returns a normalized point in `[0,1]^2`
/// with origin top-left, or nil if the point lies behind the camera.
///
/// Implementation:
///   1. World → camera-local using `inverse(cameraTransform)`.
///   2. Flip Y/Z to convert from ARKit camera (RUB) to OpenCV (RDF).
///   3. Apply intrinsics — yields **landscape** pixel coordinates,
///      because ARKit's `intrinsics` are calibrated for the raw
///      landscape-right `capturedImage`.
///   4. Rotate landscape → portrait (90° CCW) since we display the
///      reference photo in portrait via `CIImage.oriented(.right)`.
enum MeasureReprojection {

    static func projectToNormalized(
        worldPoint: SIMD3<Float>,
        frame: CapturedFrame
    ) -> CGPoint? {
        // ── 1. World → camera local ────────────────────────────────
        let inverseTransform = simd_inverse(frame.cameraTransform)
        let homog = inverseTransform * SIMD4<Float>(worldPoint, 1)
        let pCamera = SIMD3<Float>(homog.x, homog.y, homog.z)

        // ── 2. ARKit camera (right-up-back) → OpenCV (right-down-fwd)
        let pCv = SIMD3<Float>(pCamera.x, -pCamera.y, -pCamera.z)
        guard pCv.z > 1e-4 else { return nil }   // behind the camera

        // ── 3. Pinhole projection → landscape pixel coords ─────────
        let fx = frame.cameraIntrinsics[0, 0]
        let fy = frame.cameraIntrinsics[1, 1]
        let cx = frame.cameraIntrinsics[2, 0]
        let cy = frame.cameraIntrinsics[2, 1]
        let uLand = fx * pCv.x / pCv.z + cx
        let vLand = fy * pCv.y / pCv.z + cy

        // ── 4. Landscape pixel → portrait normalized (90° CCW) ─────
        // For ARKit `.oriented(.right)`:
        //   portrait_x_norm = v_land / H_land  ←  v_land in [0, H_land]
        //   portrait_y_norm = 1 - u_land / W_land
        // The portrait image's width == landscape height, height == landscape width.
        let portraitW = Float(frame.image.size.width)
        let portraitH = Float(frame.image.size.height)
        let landscapeH = portraitW
        let landscapeW = portraitH

        let xNorm = vLand / landscapeH
        let yNorm = 1 - uLand / landscapeW
        return CGPoint(x: CGFloat(xNorm), y: CGFloat(yNorm))
    }
}
#endif
