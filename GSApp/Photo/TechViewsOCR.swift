import Foundation
import UIKit
@preconcurrency import Vision

/// One line / region of text recognised by Vision, with the
/// confidence the model assigned to its top candidate.
struct OCRObservation: Identifiable, Hashable, Sendable {
    let id = UUID()
    let text: String
    let confidence: Float
}

/// Async wrapper around `VNRecognizeTextRequest`. Runs on a global
/// queue, returns a Swift array. French + English are enabled — that
/// covers the labels we'll see in practice.
enum TechViewsOCR {

    static func recognize(in image: UIImage) async throws -> [OCRObservation] {
        guard let cgImage = image.cgImage else { return [] }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLanguages = ["fr-FR", "en-US"]
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
                do {
                    try handler.perform([request])
                    let observations: [OCRObservation] = (request.results ?? []).compactMap { obs in
                        guard let topCandidate = obs.topCandidates(1).first else { return nil }
                        let text = topCandidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { return nil }
                        return OCRObservation(text: text, confidence: topCandidate.confidence)
                    }
                    continuation.resume(returning: observations)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
