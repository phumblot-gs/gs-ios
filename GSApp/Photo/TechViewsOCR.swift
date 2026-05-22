import Foundation
import UIKit
import NaturalLanguage
@preconcurrency import Vision

/// One line / region of text recognised by Vision, with the
/// confidence the model assigned to its top candidate and the
/// normalised bounding box (origin bottom-left, per Vision's
/// convention) we use for downstream layout-aware grouping.
struct OCRObservation: Identifiable, Hashable, Sendable {
    let id = UUID()
    let text: String
    let confidence: Float
    let boundingBox: CGRect
}

/// Async wrapper around `VNRecognizeTextRequest`. Runs on a global
/// queue, post-processes the result to (1) join key/value pairs that
/// Vision split apart on the same visual line, and (2) drop
/// cross-language duplicates while preferring English. French +
/// English are enabled — that covers the labels we'll see in practice.
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
                    let raw: [OCRObservation] = (request.results ?? []).compactMap { obs in
                        guard let topCandidate = obs.topCandidates(1).first else { return nil }
                        let text = topCandidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { return nil }
                        return OCRObservation(
                            text: text,
                            confidence: topCandidate.confidence,
                            boundingBox: obs.boundingBox
                        )
                    }
                    let merged = mergeKeyValueLines(raw)
                    let normalized = normalizeMultilingual(merged)
                    let deduped = removeLinguisticDuplicates(normalized)
                    continuation.resume(returning: deduped)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Key/value line merging

    /// Vision occasionally splits a single visual row of text (key on
    /// the left, value on the right) into two observations because of
    /// the wide gap between them. This pass groups observations whose
    /// vertical centres line up within half a line's height and joins
    /// them left-to-right.
    private static func mergeKeyValueLines(_ observations: [OCRObservation]) -> [OCRObservation] {
        guard observations.count > 1 else { return observations }
        var remaining = observations
        var merged: [OCRObservation] = []
        while !remaining.isEmpty {
            let first = remaining.removeFirst()
            var line = [first]
            let firstY = first.boundingBox.midY
            let yTolerance = max(first.boundingBox.height * 0.5, 0.005)
            remaining.removeAll { candidate in
                let candidateY = candidate.boundingBox.midY
                if abs(candidateY - firstY) > yTolerance { return false }
                line.append(candidate)
                return true
            }
            line.sort { $0.boundingBox.midX < $1.boundingBox.midX }
            merged.append(joined(line))
        }
        return merged
    }

    private static func joined(_ line: [OCRObservation]) -> OCRObservation {
        guard line.count > 1 else { return line[0] }
        var text = line[0].text
        for next in line.dropFirst() {
            let separator = isValueLike(next.text) ? ": " : " "
            text += separator + next.text
        }
        let avgConfidence = line.map(\.confidence).reduce(0, +) / Float(line.count)
        let unionBox = line.dropFirst().reduce(line[0].boundingBox) { acc, obs in
            acc.union(obs.boundingBox)
        }
        return OCRObservation(text: text, confidence: avgConfidence, boundingBox: unionBox)
    }

    private static func isValueLike(_ text: String) -> Bool {
        guard let first = text.first else { return false }
        if first.isNumber { return true }
        if text.contains("%") { return true }
        return false
    }

    // MARK: - Within-line multilingual normalisation

    /// On a single visual line Vision often surfaces the same word
    /// repeated in several languages — "wool lana", "acrilico
    /// acrykio", "NYLON NYLON". This pass tokenises each observation
    /// (handling stuck-together cases like "58%acrilico"), maps known
    /// textile terms to their English canonical, then drops any token
    /// whose canonical has already been emitted on the line.
    private static func normalizeMultilingual(_ observations: [OCRObservation]) -> [OCRObservation] {
        observations.map { obs in
            let cleaned = normalizeLine(obs.text)
            guard cleaned != obs.text else { return obs }
            return OCRObservation(text: cleaned, confidence: obs.confidence, boundingBox: obs.boundingBox)
        }
    }

    private static func normalizeLine(_ text: String) -> String {
        let tokens = tokenize(text)
        guard !tokens.isEmpty else { return text }
        var seen: Set<String> = []
        var output: [String] = []
        for token in tokens {
            let canonical = TechViewsDictionary.canonical(of: token)
            let key = canonical ?? token.lowercased()
            guard seen.insert(key).inserted else { continue }
            output.append(canonical ?? token)
        }
        return output.joined(separator: " ")
    }

    /// Splits a string into label-friendly tokens: runs of letters,
    /// runs of digits (with an optional trailing % attached), and
    /// other non-whitespace runs as their own atoms. Crucially it
    /// breaks letter/digit transitions, so "58%acrilico" yields
    /// ["58%", "acrilico"] even when the OCR glues them.
    private static func tokenize(_ text: String) -> [String] {
        enum Kind { case none, letter, digit, other }
        var tokens: [String] = []
        var current = ""
        var lastKind: Kind = .none

        func flush() {
            if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }

        for char in text {
            if char.isWhitespace {
                flush()
                lastKind = .none
                continue
            }
            let kind: Kind
            if char.isLetter {
                kind = .letter
            } else if char.isNumber {
                kind = .digit
            } else if char == "%" && lastKind == .digit {
                // Treat trailing % as part of the preceding number run.
                current.append(char)
                continue
            } else {
                kind = .other
            }
            if lastKind != .none && lastKind != kind {
                flush()
            }
            current.append(char)
            lastKind = kind
        }
        flush()
        return tokens
    }

    // MARK: - Linguistic deduplication

    /// Drops lines that look like translations of each other, keeping
    /// the English version when present. Match heuristic: detect
    /// language per line with NLLanguageRecognizer, compute salient
    /// tokens (numbers, % markers, words ≥ 4 letters, ALLCAPS codes)
    /// and group lines whose token sets overlap ≥ 50 %. Won't catch
    /// translations that share no proper nouns or numbers (e.g. "Hand
    /// wash" vs "Lavage à la main") — Phase E will hook the iOS
    /// Translation framework for those cases.
    private static func removeLinguisticDuplicates(_ observations: [OCRObservation]) -> [OCRObservation] {
        guard observations.count > 1 else { return observations }

        struct Tagged {
            let observation: OCRObservation
            let language: NLLanguage?
            let tokens: Set<String>
        }

        let tagged: [Tagged] = observations.map { obs in
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(obs.text)
            return Tagged(
                observation: obs,
                language: recognizer.dominantLanguage,
                tokens: salientTokens(in: obs.text)
            )
        }

        var assigned = Set<Int>()
        var result: [OCRObservation] = []
        for i in 0..<tagged.count where !assigned.contains(i) {
            var group = [i]
            assigned.insert(i)
            for j in (i + 1)..<tagged.count where !assigned.contains(j) {
                if tokensOverlap(tagged[i].tokens, tagged[j].tokens) {
                    group.append(j)
                    assigned.insert(j)
                }
            }
            if let englishIdx = group.first(where: { tagged[$0].language == .english }) {
                result.append(tagged[englishIdx].observation)
            } else if let firstIdx = group.first {
                result.append(tagged[firstIdx].observation)
            }
        }
        return result
    }

    private static func tokensOverlap(_ a: Set<String>, _ b: Set<String>) -> Bool {
        let smaller = min(a.count, b.count)
        guard smaller > 0 else { return false }
        let intersection = a.intersection(b).count
        return Float(intersection) / Float(smaller) >= 0.5
    }

    private static func salientTokens(in text: String) -> Set<String> {
        var tokens: Set<String> = []
        if text.contains("%") { tokens.insert("%") }
        let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        for raw in words {
            let word = String(raw)
            // Number tokens always count — they're rarely translated.
            if word.first?.isNumber == true {
                tokens.insert(word)
                continue
            }
            // Known textile terms collapse to their English canonical,
            // so French "coton" and Italian "cotone" yield the same
            // salient token across observations.
            if let canonical = TechViewsDictionary.canonical(of: word) {
                tokens.insert(canonical)
                continue
            }
            // Long words (≥ 4 letters) get lowercased to align across
            // capitalisations (Coton vs coton); short prepositions and
            // articles get filtered out by the length floor.
            if word.count >= 4 {
                tokens.insert(word.lowercased())
                continue
            }
            // Short ALLCAPS codes (NF, CE, EN, country codes…).
            if word.count >= 2 && word == word.uppercased() {
                tokens.insert(word)
            }
        }
        return tokens
    }
}
