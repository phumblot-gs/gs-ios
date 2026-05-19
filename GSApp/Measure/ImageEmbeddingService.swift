#if os(iOS)
import UIKit
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins

/// Computes and compares Vision feature prints. We use these as
/// "category fingerprints" stored against each `MeasureCategory` so the
/// app can suggest the most likely category when a new object is captured.
///
/// Storage format: the entire `VNFeaturePrintObservation` is archived via
/// `NSKeyedArchiver`, persisted as `Data` in SwiftData. At comparison time
/// we unarchive both sides and use the framework's `computeDistance(_:to:)`.
struct ImageEmbeddingService: Sendable {

    enum EmbeddingError: Error {
        case visionFailed(any Error)
        case noObservation
        case archivingFailed
    }

    // MARK: - Embed

    /// Compute and archive a feature-print observation for `image`. If a
    /// subject mask is provided, the image is composited against black
    /// outside the mask first — keeps the embedding focused on the object
    /// rather than the surrounding table / floor.
    static func embed(_ image: UIImage, maskedBy mask: CGImage? = nil) async throws -> Data {
        let source = mask.map { applyMask($0, to: image) ?? image } ?? image
        guard let cgImage = source.cgImage else {
            throw EmbeddingError.noObservation
        }
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([request])
                    guard let observation = request.results?.first as? VNFeaturePrintObservation else {
                        continuation.resume(throwing: EmbeddingError.noObservation)
                        return
                    }
                    do {
                        let archived = try NSKeyedArchiver.archivedData(
                            withRootObject: observation,
                            requiringSecureCoding: true
                        )
                        continuation.resume(returning: archived)
                    } catch {
                        continuation.resume(throwing: EmbeddingError.archivingFailed)
                    }
                } catch {
                    continuation.resume(throwing: EmbeddingError.visionFailed(error))
                }
            }
        }
    }

    // MARK: - Compare

    /// Euclidean distance between two archived feature prints. Lower =
    /// more similar. Returns `nil` if either blob fails to unarchive.
    static func distance(_ a: Data, _ b: Data) -> Float? {
        guard
            let obsA = try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: a),
            let obsB = try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: b)
        else {
            return nil
        }
        var distance: Float = 0
        do {
            try obsA.computeDistance(&distance, to: obsB)
            return distance
        } catch {
            return nil
        }
    }

    // MARK: - Mask helpers

    /// Composite `image` against a black background using `mask` as the
    /// alpha channel. The mask is expected to be sized to match `image`
    /// (Vision returns it that way when generated via
    /// `generateScaledMaskForImage(forInstances:from:)`).
    private static func applyMask(_ mask: CGImage, to image: UIImage) -> UIImage? {
        let inputCI = CIImage(image: image) ?? CIImage(cgImage: image.cgImage ?? mask)
        let maskCI = CIImage(cgImage: mask)
        let background = CIImage(color: .black).cropped(to: inputCI.extent)
        let filter = CIFilter.blendWithMask()
        filter.inputImage = inputCI
        filter.backgroundImage = background
        filter.maskImage = maskCI
        guard let output = filter.outputImage else { return nil }
        let context = CIContext()
        guard let cgOutput = context.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgOutput)
    }
}

// MARK: - Suggestion ranking helper

struct CategorySuggestion: Identifiable, Hashable {
    let id: PersistentIdentifier
    let categoryName: String
    let distance: Float
    let category: MeasureCategory

    static func == (lhs: CategorySuggestion, rhs: CategorySuggestion) -> Bool {
        lhs.id == rhs.id && lhs.distance == rhs.distance
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(distance)
    }
}

// We can't conform to Identifiable with PersistentIdentifier without
// importing SwiftData; pulling it in here for the helper.
import SwiftData
#endif
