#if os(iOS)
import Foundation
import CoreGraphics
import UIKit

/// Pre-rasterized mask of the kept subjects used during placement to
/// gate the reticle: only positions whose reprojection lands inside
/// the mask let the stability tracker progress. We also flag pixels
/// near the mask boundary as "edges" so the placing overlay can push
/// a stronger haptic + tighten the stability thresholds for hooking
/// the reticle onto product borders.
struct SubjectMaskGrid {

    enum Surface { case off, subject, edge }

    let width: Int
    let height: Int
    let onSubject: [Bool]
    let nearEdge: [Bool]

    static var empty: SubjectMaskGrid {
        SubjectMaskGrid(width: 0, height: 0, onSubject: [], nearEdge: [])
    }

    var isEmpty: Bool { onSubject.isEmpty }

    /// Sample the grid at a normalized image-space point (origin
    /// top-left, [0, 1]²). Out-of-range returns `.off` rather than
    /// clamping — we don't want to consider points outside the image
    /// frame as anything but "off target".
    func sample(normalizedImagePoint p: CGPoint) -> Surface {
        guard !isEmpty,
              p.x >= 0, p.x <= 1,
              p.y >= 0, p.y <= 1 else { return .off }
        let x = Int(p.x * CGFloat(width - 1))
        let y = Int(p.y * CGFloat(height - 1))
        guard onSubject[y * width + x] else { return .off }
        return nearEdge[y * width + x] ? .edge : .subject
    }
}

enum SubjectMaskGridBuilder {

    /// Builds the grid at a coarse resolution (~128 px on the long
    /// side). Coarse is fine — we only sample one pixel per frame and
    /// the boundary fudge below smooths out aliasing.
    static func build(subjects: [DetectedSubject], imageSize: CGSize) -> SubjectMaskGrid {
        guard !subjects.isEmpty,
              imageSize.width > 0, imageSize.height > 0 else { return .empty }

        let longest = max(imageSize.width, imageSize.height)
        let scale = 128 / longest
        let w = Int(imageSize.width * scale)
        let h = Int(imageSize.height * scale)
        guard w > 0, h > 0,
              let context = CGContext(
                  data: nil,
                  width: w,
                  height: h,
                  bitsPerComponent: 8,
                  bytesPerRow: w,
                  space: CGColorSpaceCreateDeviceGray(),
                  bitmapInfo: CGImageAlphaInfo.none.rawValue
              ) else { return .empty }

        // Rasterize each subject's mask at its bounding-box location.
        // Bounding box origin is top-left in normalized image space.
        // CGContext's coordinate system is bottom-left — convert.
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        context.setBlendMode(.lighten)
        for subject in subjects {
            let box = subject.boundingBox
            let rect = CGRect(
                x: box.minX * CGFloat(w),
                y: CGFloat(h) - (box.maxY * CGFloat(h)),
                width: box.width * CGFloat(w),
                height: box.height * CGFloat(h)
            )
            // CGContext flips Y on draw; mask CGImage is top-left
            // origin, so we draw inside a flipped sub-context.
            context.saveGState()
            context.translateBy(x: rect.minX, y: rect.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(subject.mask, in: CGRect(origin: .zero, size: rect.size))
            context.restoreGState()
        }

        guard let buffer = context.data else { return .empty }
        let pixels = buffer.bindMemory(to: UInt8.self, capacity: w * h)
        var on = [Bool](repeating: false, count: w * h)
        // The CGContext rasterized with Y-up; flip to top-left origin
        // so the sampling math matches the reprojection output.
        for y in 0..<h {
            for x in 0..<w {
                let raw = pixels[(h - 1 - y) * w + x]
                on[y * w + x] = raw > 128
            }
        }
        let edges = computeEdges(mask: on, width: w, height: h, radius: 3)
        return SubjectMaskGrid(width: w, height: h, onSubject: on, nearEdge: edges)
    }

    /// An "edge" pixel is on the subject and within `radius` of an
    /// off-subject pixel (Chebyshev distance). Computed once at build
    /// time so per-frame sampling is O(1).
    private static func computeEdges(mask: [Bool], width: Int, height: Int, radius: Int) -> [Bool] {
        var edges = [Bool](repeating: false, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                guard mask[y * width + x] else { continue }
                let x0 = Swift.max(0, x - radius)
                let x1 = Swift.min(width - 1, x + radius)
                let y0 = Swift.max(0, y - radius)
                let y1 = Swift.min(height - 1, y + radius)
                var nearOff = false
                outer: for yy in y0...y1 {
                    for xx in x0...x1 {
                        if !mask[yy * width + xx] {
                            nearOff = true
                            break outer
                        }
                    }
                }
                edges[y * width + x] = nearOff
            }
        }
        return edges
    }
}
#endif
