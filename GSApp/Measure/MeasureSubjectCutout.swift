#if os(iOS)
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Composes the included subjects onto a white background, producing
/// the "détouré sur blanc" reference photo used in the summary view.
/// Pixels inside the union of every kept subject mask are kept from the
/// original frame; everything else is replaced with white.
enum MeasureSubjectCutout {

    /// Returns the cutout image at the same resolution as `frame.image`.
    /// Falls back to the original image when there are no subjects or
    /// when masking fails — better to show the raw photo than nothing.
    static func make(frame: CapturedFrame, includedSubjects: [DetectedSubject]) -> UIImage {
        guard !includedSubjects.isEmpty,
              let cgImage = frame.image.cgImage else {
            return frame.image
        }

        let context = CIContext()
        let baseImage = CIImage(cgImage: cgImage)
        let extent = baseImage.extent

        // Each `subject.mask` is full-image-sized; the silhouette is
        // already spatially aligned with the base image. We just
        // compose them via lighten (max) compositing — no per-subject
        // bounding-box scaling needed (that would squash the
        // silhouette into the box, the bug we hit in SubjectMaskGrid).
        var unionMask: CIImage? = nil
        for subject in includedSubjects {
            var placed = CIImage(cgImage: subject.mask)
            if placed.extent.size != extent.size {
                // Defensive fallback in case Vision ever returns a
                // mask that isn't quite at the source dimensions.
                let scaleX = extent.width / placed.extent.width
                let scaleY = extent.height / placed.extent.height
                placed = placed.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            }
            if let existing = unionMask {
                let combine = CIFilter.maximumCompositing()
                combine.inputImage = placed
                combine.backgroundImage = existing
                unionMask = combine.outputImage ?? placed
            } else {
                unionMask = placed
            }
        }
        guard let mask = unionMask?.cropped(to: extent) else {
            return frame.image
        }

        // 2. Blend with mask: subject pixels from the original, rest white.
        let white = CIImage(color: .white).cropped(to: extent)
        let blend = CIFilter.blendWithMask()
        blend.inputImage = baseImage
        blend.backgroundImage = white
        blend.maskImage = mask
        guard let composed = blend.outputImage,
              let outCG = context.createCGImage(composed, from: extent) else {
            return frame.image
        }
        return UIImage(cgImage: outCG, scale: frame.image.scale, orientation: .up)
    }
}

#endif
