#if os(iOS)
import UIKit
@preconcurrency import Vision

/// One subject detected by `VNGenerateForegroundInstanceMaskRequest`,
/// presented to the user as a tappable region they can choose to
/// include or exclude from the measurement.
struct DetectedSubject: Identifiable, Equatable {
    let id: Int
    /// The mask image for this specific subject, sized to match the
    /// source image (alpha channel = subject probability).
    let mask: CGImage
    /// Subject bounding box in normalized image-space coordinates
    /// (origin top-left, range 0...1). Used for hit-testing taps.
    let boundingBox: CGRect
    var included: Bool = true

    static func == (lhs: DetectedSubject, rhs: DetectedSubject) -> Bool {
        lhs.id == rhs.id && lhs.included == rhs.included
    }
}

/// Runs `VNGenerateForegroundInstanceMaskRequest` on a captured frame
/// and returns one `DetectedSubject` per recognised instance. Anything
/// the user later marks as `included = false` is excluded from the
/// measurement scope downstream.
struct SubjectMaskService: Sendable {

    enum Error: Swift.Error {
        case noSubjects
        case visionFailed(any Swift.Error)
    }

    /// Walks the mask's alpha channel and returns a tight bounding box
    /// in normalized coordinates (origin top-left, range 0...1). The mask
    /// is typically 256x192 — small enough to iterate by hand without
    /// noticeable overhead.
    private static func boundingBox(of mask: CGImage) -> CGRect {
        let width = mask.width
        let height = mask.height
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        context.draw(mask, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height)
        var minX = width, minY = height, maxX = 0, maxY = 0
        for y in 0..<height {
            for x in 0..<width {
                if pixels[y * width + x] > 128 {
                    if x < minX { minX = x }
                    if y < minY { minY = y }
                    if x > maxX { maxX = x }
                    if y > maxY { maxY = y }
                }
            }
        }
        guard minX <= maxX, minY <= maxY else {
            return CGRect(x: 0, y: 0, width: 0, height: 0)
        }
        let w = CGFloat(width)
        let h = CGFloat(height)
        return CGRect(
            x: CGFloat(minX) / w,
            y: CGFloat(minY) / h,
            width: CGFloat(maxX - minX + 1) / w,
            height: CGFloat(maxY - minY + 1) / h
        )
    }

    /// Asynchronously detect every foreground subject in `image`.
    /// Returns an empty array if Vision found nothing (typical when the
    /// frame is plain wall / empty floor).
    static func detect(in image: UIImage) async throws -> [DetectedSubject] {
        guard let cgImage = image.cgImage else { return [] }

        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([request])
                    guard let observation = request.results?.first else {
                        continuation.resume(returning: [])
                        return
                    }
                    var subjects: [DetectedSubject] = []
                    for index in observation.allInstances {
                        do {
                            let pixelBuffer = try observation.generateScaledMaskForImage(
                                forInstances: [index],
                                from: handler
                            )
                            let maskImage = CIImage(cvPixelBuffer: pixelBuffer)
                            let context = CIContext()
                            guard let cgMask = context.createCGImage(maskImage, from: maskImage.extent) else {
                                continue
                            }
                            let bb = boundingBox(of: cgMask)
                            subjects.append(DetectedSubject(
                                id: index,
                                mask: cgMask,
                                boundingBox: bb
                            ))
                        } catch {
                            // Skip this subject if mask generation fails;
                            // others are still usable.
                            continue
                        }
                    }
                    continuation.resume(returning: subjects)
                } catch {
                    continuation.resume(throwing: Error.visionFailed(error))
                }
            }
        }
    }
}
#endif
