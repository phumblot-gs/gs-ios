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

        // 1. Union of every subject mask into one CIImage. Each mask is
        //    drawn at its bounding-box location in normalized image-
        //    space; we map that into pixel-space first.
        var unionMask: CIImage? = nil
        for subject in includedSubjects {
            let maskCG = subject.mask
            let maskCI = CIImage(cgImage: maskCG)
            let box = subject.boundingBox    // top-left origin, normalized
            // Image-space rect of this subject inside the portrait frame.
            let pixelRect = CGRect(
                x: box.minX * extent.width,
                y: (1 - box.maxY) * extent.height,
                width: box.width * extent.width,
                height: box.height * extent.height
            )
            // Scale + translate the mask to that rect.
            let scaleX = pixelRect.width / maskCI.extent.width
            let scaleY = pixelRect.height / maskCI.extent.height
            let placed = maskCI
                .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
                .transformed(by: CGAffineTransform(translationX: pixelRect.minX, y: pixelRect.minY))
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
