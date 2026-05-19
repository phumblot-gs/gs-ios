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

    /// Render the grid as a translucent RGBA UIImage for debugging:
    /// green where the surface classifies as `.subject`, orange where
    /// it's `.edge`, transparent elsewhere. Used by the placement
    /// debug overlay to show what the mask check actually sees.
    func renderAsImage() -> UIImage? {
        guard !isEmpty else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            if nearEdge[i] {
                pixels[i * 4 + 0] = 255   // R
                pixels[i * 4 + 1] = 165   // G
                pixels[i * 4 + 2] = 0     // B
                pixels[i * 4 + 3] = 180   // A
            } else if onSubject[i] {
                pixels[i * 4 + 0] = 0     // R
                pixels[i * 4 + 1] = 220   // G
                pixels[i * 4 + 2] = 100   // B
                pixels[i * 4 + 3] = 160   // A
            }
            // off-subject pixels stay at (0, 0, 0, 0) — transparent
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)
        guard let provider,
              let cgImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else { return nil }
        return UIImage(cgImage: cgImage)
    }

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

    /// Builds the grid at ~256 px on the long side. Going coarser
    /// (e.g. 128) makes the per-cell downsampling smear narrow parts
    /// of the silhouette below the binarization threshold — a thin
    /// car body shrinks down to nothing and only the wheels survive
    /// as `subject`, which is what the user reported.
    static func build(subjects: [DetectedSubject], imageSize: CGSize) -> SubjectMaskGrid {
        guard !subjects.isEmpty,
              imageSize.width > 0, imageSize.height > 0 else { return .empty }

        let longest = max(imageSize.width, imageSize.height)
        let scale = 256 / longest
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

        // Each `subject.mask` is full-image-sized (white inside the
        // silhouette, black elsewhere — see
        // `generateScaledMaskForImage`). Drawing it at the full grid
        // rect scales the whole thing down to the grid resolution
        // while preserving the silhouette's spatial position. The
        // `boundingBox` on the subject is informational and we don't
        // need it here — using it as the destination rect would
        // squash the silhouette by an extra factor, which is the bug
        // we fixed by moving back to a full-rect draw.
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        context.setBlendMode(.lighten)
        let fullRect = CGRect(x: 0, y: 0, width: w, height: h)
        for subject in subjects {
            context.draw(subject.mask, in: fullRect)
        }

        guard let buffer = context.data else { return .empty }
        let pixels = buffer.bindMemory(to: UInt8.self, capacity: w * h)
        var on = [Bool](repeating: false, count: w * h)
        // Memory is already in top-left origin (top-down rows) thanks
        // to CGContext's default layout — read straight through.
        // Threshold > 64 (≈ 25 % coverage of the patch) rather than
        // 128 — even at 256 px on the long side, narrow silhouettes
        // (a car body, a sleeve) average below 128 along their thin
        // axis and would drop out. 64 keeps the full silhouette while
        // still rejecting the soft anti-aliased halo Vision adds
        // around the subject's boundary.
        for i in 0..<(w * h) {
            on[i] = pixels[i] > 64
        }
        // Edge radius scales with the grid: 2.3 % of the long side
        // (same proportion as the previous 3 px on 128 px) keeps the
        // edge band physically the same width while doubling the
        // pixel headroom for stability.
        let edges = computeEdges(mask: on, width: w, height: h, radius: 6)
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
