#if os(iOS)
import Foundation
import ARKit
import CoreVideo
import simd

/// Projects a 2D screen-space tap into a 3D point in camera coordinates,
/// using the depth map captured at the same moment. We work in the
/// captured frame's reference (no live AR raycast needed — the photo is
/// frozen on screen) so measurements stay stable while the user repositions
/// the device.
enum DepthRaycaster {

    /// `normalizedPoint` lives in image-space with origin top-left and
    /// values in [0, 1]. Returns the 3D position in camera coordinates
    /// (units = meters), or nil if the depth lookup fails or is invalid.
    static func project(
        normalizedPoint: CGPoint,
        depthMap: CVPixelBuffer,
        intrinsics: simd_float3x3,
        imageSize: CGSize
    ) -> SIMD3<Float>? {
        let depthWidth = CVPixelBufferGetWidth(depthMap)
        let depthHeight = CVPixelBufferGetHeight(depthMap)

        // Sample the depth value at the normalized point.
        let dx = Int((normalizedPoint.x.clamped(to: 0...1)) * CGFloat(depthWidth - 1))
        let dy = Int((normalizedPoint.y.clamped(to: 0...1)) * CGFloat(depthHeight - 1))

        guard let depth = sampleDepth(at: (dx, dy), buffer: depthMap),
              depth > 0,
              depth.isFinite else {
            return nil
        }

        // Camera intrinsics are calibrated for the captured image size,
        // not the depth map size. Translate the normalized tap into
        // image-space pixels for the back-projection.
        let pixelX = Float(normalizedPoint.x) * Float(imageSize.width)
        let pixelY = Float(normalizedPoint.y) * Float(imageSize.height)

        let fx = intrinsics[0, 0]
        let fy = intrinsics[1, 1]
        let cx = intrinsics[2, 0]
        let cy = intrinsics[2, 1]

        let z = depth
        let x = (pixelX - cx) * z / fx
        let y = (pixelY - cy) * z / fy
        return SIMD3<Float>(x, y, z)
    }

    /// Convenience: distance through a chain of N points (sum of segments).
    static func chainDistance(_ points: [SIMD3<Float>]) -> Float {
        guard points.count > 1 else { return 0 }
        var total: Float = 0
        for i in 0..<(points.count - 1) {
            total += simd_distance(points[i], points[i + 1])
        }
        return total
    }

    private static func sampleDepth(at point: (Int, Int), buffer: CVPixelBuffer) -> Float? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let format = CVPixelBufferGetPixelFormatType(buffer)
        // Expected format: kCVPixelFormatType_DepthFloat32 (Float32 in meters).
        guard format == kCVPixelFormatType_DepthFloat32 else { return nil }
        let rowPointer = base.advanced(by: point.1 * bytesPerRow)
        let floatPointer = rowPointer.assumingMemoryBound(to: Float.self)
        return floatPointer[point.0]
    }
}

extension CGFloat {
    /// File-internal helper but exposed within the Measure subsystem so
    /// `MeasurePointPlacementView` can clamp drag positions to the
    /// rendered image rect.
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
#endif
