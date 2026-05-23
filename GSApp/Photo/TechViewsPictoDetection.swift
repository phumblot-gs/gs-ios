import Foundation
import UIKit
@preconcurrency import Vision

/// Auto-detects pictogram candidates on a captured tech-view photo.
/// The pipeline:
///   1. Run Vision's contour detector at a downscaled resolution so
///      it stays interactive.
///   2. Filter contours by size and aspect ratio to cull texture
///      noise (fabric grain, threads, dust) — we keep boxes that
///      look like care symbols.
///   3. Subtract anything that overlaps an OCR text box, since we
///      only want non-textual icons.
///   4. Cluster nearby contours into single regions (a triangle with
///      an "X" inside fires several contours that should merge).
///   5. Crop each surviving region and compute a Vision feature
///      print embedding so the UI can ask `TechViewsPictoMatcher`
///      for a learned label.
enum TechViewsPictoDetection {

    /// Distance threshold above which the matcher considers two
    /// feature prints to represent different pictograms.
    /// `VNFeaturePrintObservation.computeDistance(_:to:)` is a
    /// non-normalised Euclidean distance on a 2048-dim float vector;
    /// from spot-checks on care symbols ≤ 12 reliably picks "same
    /// icon", ≤ 18 picks "same family", > 22 is noise. We default
    /// to 18 — the threshold will move to Settings in Phase E.
    static let suggestionThreshold: Float = 18

    struct Candidate: Identifiable, Sendable {
        let id = UUID()
        /// Vision-normalised bounding box (origin bottom-left, axes
        /// in [0, 1]).
        let boundingBox: CGRect
        /// JPEG-friendly crop of the original photo, padded slightly
        /// to give the embedding some context.
        let crop: UIImage
        /// `VNFeaturePrintObservation` archived via NSKeyedArchiver
        /// — round-trippable for nearest-neighbour matching and
        /// persistable when the user teaches us a new picto.
        let featurePrintData: Data
    }

    static func detect(
        in image: UIImage,
        excluding textBoxes: [CGRect]
    ) async throws -> [Candidate] {
        guard let cgImage = image.cgImage else { return [] }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let rawBoxes = try detectContourBoxes(in: cgImage)
                    let filtered = filter(rawBoxes, excluding: textBoxes)
                    let clustered = clusterByIoU(filtered, threshold: 0.15)
                    let candidates = materialise(
                        clustered,
                        source: cgImage,
                        originalScale: image.scale
                    )
                    continuation.resume(returning: candidates)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Encodes a Vision feature-print observation to a plain `Data`
    /// blob using `NSKeyedArchiver`. The reverse operation lives in
    /// `TechViewsPictoMatcher` so the matcher owns decode + compare.
    static func encode(featurePrint: VNFeaturePrintObservation) throws -> Data {
        try NSKeyedArchiver.archivedData(
            withRootObject: featurePrint,
            requiringSecureCoding: true
        )
    }

    // MARK: - Vision passes

    private static func detectContourBoxes(in cgImage: CGImage) throws -> [CGRect] {
        let request = VNDetectContoursRequest()
        request.contrastAdjustment = 2.0
        request.detectsDarkOnLight = true
        request.maximumImageDimension = 1024
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])
        guard let observation = request.results?.first else { return [] }
        return allContourBoxes(in: observation)
    }

    /// Walk every contour level, not just `topLevelContours` — care
    /// symbols often sit inside an outer frame contour, and we want
    /// the inner icon's box too.
    private static func allContourBoxes(in observation: VNContoursObservation) -> [CGRect] {
        var out: [CGRect] = []
        func walk(_ contour: VNContour) {
            out.append(contour.normalizedPath.boundingBox)
            for child in contour.childContours { walk(child) }
        }
        for top in observation.topLevelContours { walk(top) }
        return out
    }

    // MARK: - Filtering

    private static func filter(_ boxes: [CGRect], excluding text: [CGRect]) -> [CGRect] {
        boxes.filter { box in
            let area = box.width * box.height
            // Pictos fall roughly between 0.08 % and 6 % of the photo.
            // Below that → fabric noise; above → likely the whole
            // label or a hand silhouette.
            guard area > 0.0008 && area < 0.06 else { return false }
            let aspect = box.width / max(box.height, 0.0001)
            // Care symbols are roughly square-ish.
            guard aspect > 0.4 && aspect < 2.5 else { return false }
            for textBox in text where box.intersection(textBox).gsArea > 0.4 * box.gsArea {
                return false
            }
            return true
        }
    }

    private static func clusterByIoU(_ boxes: [CGRect], threshold: Double) -> [CGRect] {
        var clusters: [[CGRect]] = []
        for box in boxes {
            if let idx = clusters.firstIndex(where: { cluster in
                cluster.contains { iou(box, $0) > threshold }
            }) {
                clusters[idx].append(box)
            } else {
                clusters.append([box])
            }
        }
        return clusters.map { cluster in
            cluster.dropFirst().reduce(cluster[0]) { $0.union($1) }
        }
    }

    // MARK: - Crop + feature print

    private static func materialise(
        _ boxes: [CGRect],
        source cgImage: CGImage,
        originalScale: CGFloat
    ) -> [Candidate] {
        let imageWidth = CGFloat(cgImage.width)
        let imageHeight = CGFloat(cgImage.height)
        var out: [Candidate] = []
        for box in boxes {
            // Pad the crop a little — feature prints work better
            // with some breathing room around the icon.
            let padded = box.insetBy(dx: -box.width * 0.15, dy: -box.height * 0.15)
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            let pixelRect = CGRect(
                x: padded.minX * imageWidth,
                y: (1 - padded.maxY) * imageHeight,
                width: padded.width * imageWidth,
                height: padded.height * imageHeight
            ).integral
            guard pixelRect.width >= 24,
                  pixelRect.height >= 24,
                  let cropped = cgImage.cropping(to: pixelRect) else { continue }
            do {
                let embedding = try computeFeaturePrint(of: cropped)
                let cropImage = UIImage(
                    cgImage: cropped,
                    scale: originalScale,
                    orientation: .up
                )
                out.append(Candidate(
                    boundingBox: box,
                    crop: cropImage,
                    featurePrintData: embedding
                ))
            } catch {
                continue
            }
        }
        return out
    }

    private static func computeFeaturePrint(of cgImage: CGImage) throws -> Data {
        let request = VNGenerateImageFeaturePrintRequest()
        request.imageCropAndScaleOption = .centerCrop
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])
        guard let observation = (request.results as? [VNFeaturePrintObservation])?.first else {
            throw NSError(
                domain: "TechViewsPictoDetection.featurePrint",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No feature print observation"]
            )
        }
        return try encode(featurePrint: observation)
    }

    // MARK: - Geometry

    private static func iou(_ a: CGRect, _ b: CGRect) -> Double {
        let inter = a.intersection(b)
        guard !inter.isNull, !inter.isEmpty else { return 0 }
        let interArea = Double(inter.width * inter.height)
        let unionArea = Double(a.width * a.height + b.width * b.height) - interArea
        return unionArea > 0 ? interArea / unionArea : 0
    }
}

private extension CGRect {
    /// `area` is taken by SwiftUI elsewhere; namespacing avoids the
    /// clash on adoption.
    var gsArea: CGFloat { width * height }
}
