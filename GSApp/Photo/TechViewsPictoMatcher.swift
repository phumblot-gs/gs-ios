import Foundation
import SwiftData
@preconcurrency import Vision

/// Nearest-neighbour lookup of a freshly-detected picto candidate
/// against the learned picto library stored in SwiftData. Distance
/// is the raw `VNFeaturePrintObservation.computeDistance` value; we
/// surface a suggestion only when the closest learned picto sits
/// within `TechViewsPictoDetection.suggestionThreshold`.
@MainActor
enum TechViewsPictoMatcher {

    struct Suggestion: Hashable, Sendable {
        let learnedID: PersistentIdentifier
        let label: String
        let categoryRawValue: String
        let distance: Float
    }

    /// Returns the best matching learned picto if its distance to
    /// the candidate is within the suggestion threshold. Walks the
    /// full library — fine for label volumes (≤ low hundreds).
    static func bestMatch(
        for candidate: TechViewsPictoDetection.Candidate,
        in library: [LearnedPictogram],
        threshold: Float = TechViewsPictoDetection.suggestionThreshold
    ) -> Suggestion? {
        guard let candidateObservation = try? decode(candidate.featurePrintData) else { return nil }
        var best: (distance: Float, pictogram: LearnedPictogram)?
        for pictogram in library {
            guard let learnedObservation = try? decode(pictogram.embedding) else { continue }
            var distance: Float = .greatestFiniteMagnitude
            do {
                try candidateObservation.computeDistance(&distance, to: learnedObservation)
            } catch {
                continue
            }
            if best == nil || distance < best!.distance {
                best = (distance, pictogram)
            }
        }
        guard let (distance, pictogram) = best, distance <= threshold else { return nil }
        return Suggestion(
            learnedID: pictogram.persistentModelID,
            label: pictogram.label,
            categoryRawValue: pictogram.categoryRawValue,
            distance: distance
        )
    }

    /// Computes the distances from a candidate to every learned
    /// picto, sorted ascending. Useful when the UI wants to offer
    /// "use a near miss" as a recovery option instead of forcing
    /// the user to retype a known label.
    static func nearestNeighbours(
        for candidate: TechViewsPictoDetection.Candidate,
        in library: [LearnedPictogram],
        limit: Int = 3
    ) -> [(LearnedPictogram, Float)] {
        guard let candidateObservation = try? decode(candidate.featurePrintData) else { return [] }
        var ranked: [(LearnedPictogram, Float)] = []
        for pictogram in library {
            guard let learnedObservation = try? decode(pictogram.embedding) else { continue }
            var distance: Float = .greatestFiniteMagnitude
            if (try? candidateObservation.computeDistance(&distance, to: learnedObservation)) != nil {
                ranked.append((pictogram, distance))
            }
        }
        ranked.sort { $0.1 < $1.1 }
        return Array(ranked.prefix(limit))
    }

    private static func decode(_ data: Data) throws -> VNFeaturePrintObservation {
        guard let observation = try NSKeyedUnarchiver.unarchivedObject(
            ofClass: VNFeaturePrintObservation.self,
            from: data
        ) else {
            throw NSError(
                domain: "TechViewsPictoMatcher.decode",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Could not decode feature print"]
            )
        }
        return observation
    }
}
