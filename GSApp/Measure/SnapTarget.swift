#if os(iOS)
import Foundation
import CoreImage
import CoreVideo
import UIKit

/// Precomputed "where can a point land?" lookup combining:
///   - the union of every included subject mask (we only let points
///     drop on the object the user kept), and
///   - which pixels have a valid LiDAR depth reading.
///
/// Built once on screen entry; queried every tap / drag to snap the
/// user's choice to the nearest acceptable position.
struct SnapTarget {
    let mask: [Bool]            // row-major, width*height
    let width: Int
    let height: Int

    /// Empty target = nothing on the object, any position passes through.
    static let empty = SnapTarget(mask: [], width: 0, height: 0)

    var isEmpty: Bool { mask.isEmpty }

    /// Returns true if the normalized point lies inside the snap target.
    func contains(normalizedPoint: CGPoint) -> Bool {
        guard !isEmpty else { return true }
        let x = Int(normalizedPoint.x.clamped(to: 0...1) * CGFloat(width - 1))
        let y = Int(normalizedPoint.y.clamped(to: 0...1) * CGFloat(height - 1))
        return mask[y * width + x]
    }

    /// Spiral-search outward from `normalizedPoint` until we find a pixel
    /// that lies inside the snap target. Returns nil if none within
    /// `maxRadius` pixels (in target-space).
    func nearest(to normalizedPoint: CGPoint, maxRadius: Int = 80) -> CGPoint? {
        guard !isEmpty else { return normalizedPoint }
        let cx = Int(normalizedPoint.x.clamped(to: 0...1) * CGFloat(width - 1))
        let cy = Int(normalizedPoint.y.clamped(to: 0...1) * CGFloat(height - 1))
        if test(x: cx, y: cy) {
            return normalizedPoint
        }
        for radius in 1...maxRadius {
            // Scan the square ring at the given Chebyshev distance.
            // It's not perfectly Euclidean but cheap and visually
            // indistinguishable at the pixel scales we care about.
            let x0 = cx - radius
            let x1 = cx + radius
            let y0 = cy - radius
            let y1 = cy + radius
            var best: (x: Int, y: Int, d2: Int)? = nil
            for x in x0...x1 {
                for y in [y0, y1] {
                    if test(x: x, y: y) {
                        let dx = x - cx, dy = y - cy
                        let d2 = dx * dx + dy * dy
                        if best == nil || d2 < best!.d2 {
                            best = (x, y, d2)
                        }
                    }
                }
            }
            for y in (y0 + 1)...(y1 - 1) {
                for x in [x0, x1] {
                    if test(x: x, y: y) {
                        let dx = x - cx, dy = y - cy
                        let d2 = dx * dx + dy * dy
                        if best == nil || d2 < best!.d2 {
                            best = (x, y, d2)
                        }
                    }
                }
            }
            if let best {
                return CGPoint(
                    x: CGFloat(best.x) / CGFloat(width - 1),
                    y: CGFloat(best.y) / CGFloat(height - 1)
                )
            }
        }
        return nil
    }

    private func test(x: Int, y: Int) -> Bool {
        guard (0..<width).contains(x), (0..<height).contains(y) else { return false }
        return mask[y * width + x]
    }
}

/// Builder. Produces a `SnapTarget` from the included subject masks +
/// the captured depth buffer. The output resolution matches the depth
/// map (typically 256x192) — coarse enough to keep memory tiny but fine
/// enough that the snap is visually imperceptible.
enum SnapTargetBuilder {
    static func build(
        subjects: [DetectedSubject],
        depthMap: CVPixelBuffer?,
        imageSize: CGSize
    ) -> SnapTarget {
        guard let depthMap else { return .empty }
        let dw = CVPixelBufferGetWidth(depthMap)
        let dh = CVPixelBufferGetHeight(depthMap)
        guard dw > 0, dh > 0 else { return .empty }

        // 1. Pack each subject mask into a [Bool] at the depth-map
        //    resolution. Union them into a single boolean grid.
        var inMask = [Bool](repeating: false, count: dw * dh)
        if subjects.isEmpty {
            // No mask available → don't constrain by mask. The user's
            // point will still be snapped to valid depth pixels below.
            for i in 0..<(dw * dh) { inMask[i] = true }
        } else {
            for subject in subjects {
                blit(maskImage: subject.mask, into: &inMask, width: dw, height: dh)
            }
        }

        // 2. AND with depth validity (depth > 0 and finite).
        guard CVPixelBufferLockBaseAddress(depthMap, .readOnly) == kCVReturnSuccess else {
            return SnapTarget(mask: inMask, width: dw, height: dh)
        }
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(depthMap),
              CVPixelBufferGetPixelFormatType(depthMap) == kCVPixelFormatType_DepthFloat32 else {
            return SnapTarget(mask: inMask, width: dw, height: dh)
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        for y in 0..<dh {
            let rowPtr = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: Float.self)
            for x in 0..<dw {
                let z = rowPtr[x]
                if !(z > 0 && z.isFinite) {
                    inMask[y * dw + x] = false
                }
            }
        }
        return SnapTarget(mask: inMask, width: dw, height: dh)
    }

    /// Draw `maskImage` into the boolean grid by sampling it at
    /// `(width, height)`. Anything brighter than 50% counts as "on the
    /// subject."
    private static func blit(maskImage: CGImage, into out: inout [Bool], width: Int, height: Int) {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return }
        context.draw(maskImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let buffer = context.data else { return }
        let pixels = buffer.bindMemory(to: UInt8.self, capacity: width * height)
        for i in 0..<(width * height) where pixels[i] > 128 {
            out[i] = true
        }
    }
}
#endif
