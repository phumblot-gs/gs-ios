import Foundation
import GSAPIClient

/// Tracks the next `{INC}` value to use for each filename pattern
/// the capture flow can produce. Seeded from the list of files
/// already uploaded to today's GS production so that a re-entry
/// into the flow on the same day never overwrites a previous
/// shot, even when the user mixes capture modes (Presentation,
/// Detail, OCR) whose patterns may all resolve to the same
/// filename family.
///
/// Counter slots are keyed by the **fully-substituted** template
/// (i.e. `{EAN}` / `{REF}` replaced but `{INC}` preserved). So
/// two patterns that produce the same filename family for a
/// given reference automatically share a slot, and any pattern
/// difference (different prefix, different placeholder mix) gets
/// its own independent counter.
struct TechViewsFilenameCounter {
    private var nextInc: [String: Int] = [:]

    /// Resolves the next filename for `pattern` against the
    /// reference's `ean` / `ref`, then bumps the counter for that
    /// family.
    mutating func take(pattern: String, ean: String?, ref: String) -> String {
        let key = familyKey(pattern: pattern, ean: ean, ref: ref)
        let inc = nextInc[key] ?? 1
        nextInc[key] = inc + 1
        return DevSettings.renderFilename(
            template: pattern,
            ean: ean,
            ref: ref,
            inc: inc
        )
    }

    /// Pre-populates the counter from the filenames already on GS
    /// for today's production. For each pattern, scans the
    /// existing list for any match (regex-built from the
    /// substituted template with `{INC}` as a capture group),
    /// takes the maximum existing inc, and stores `max + 1`.
    /// Patterns that share a family receive the same seed value.
    mutating func seed(
        from existingFilenames: [String],
        patterns: [String],
        ean: String?,
        ref: String
    ) {
        for pattern in patterns {
            let key = familyKey(pattern: pattern, ean: ean, ref: ref)
            guard nextInc[key] == nil else { continue }   // already seeded by a sibling pattern
            let highest = highestExistingInc(
                in: existingFilenames,
                pattern: pattern,
                ean: ean,
                ref: ref
            )
            nextInc[key] = highest + 1
        }
    }

    // MARK: - Internals

    private func familyKey(pattern: String, ean: String?, ref: String) -> String {
        let eanValue = (ean?.isEmpty == false) ? ean! : ref
        return pattern
            .replacingOccurrences(of: "{EAN}", with: eanValue)
            .replacingOccurrences(of: "{REF}", with: ref)
    }

    private func highestExistingInc(
        in filenames: [String],
        pattern: String,
        ean: String?,
        ref: String
    ) -> Int {
        guard let regex = Self.regex(forPattern: pattern, ean: ean, ref: ref) else { return 0 }
        var maxInc = 0
        for filename in filenames {
            let nsRange = NSRange(filename.startIndex..., in: filename)
            guard let match = regex.firstMatch(in: filename, range: nsRange),
                  match.numberOfRanges >= 2,
                  let r = Range(match.range(at: 1), in: filename),
                  let inc = Int(filename[r])
            else { continue }
            maxInc = Swift.max(maxInc, inc)
        }
        return maxInc
    }

    /// Returns true if `filename` could have been produced by
    /// `pattern` for the given `ean` / `ref` (any `{INC}`). Useful
    /// for filtering a Picture list to find shots matching a
    /// specific template — e.g. "give me the measurement
    /// illustration uploaded for this reference".
    static func filename(
        _ filename: String,
        matches pattern: String,
        ean: String?,
        ref: String
    ) -> Bool {
        guard let regex = regex(forPattern: pattern, ean: ean, ref: ref) else { return false }
        let nsRange = NSRange(filename.startIndex..., in: filename)
        return regex.firstMatch(in: filename, range: nsRange) != nil
    }

    private static func regex(
        forPattern pattern: String,
        ean: String?,
        ref: String
    ) -> NSRegularExpression? {
        let eanValue = (ean?.isEmpty == false) ? ean! : ref
        // Split on {INC}, substitute EAN/REF in each segment,
        // regex-escape, glue with a numeric capture group.
        let parts = pattern.components(separatedBy: "{INC}")
        guard parts.count >= 1 else { return nil }
        let escapedParts = parts.map { part -> String in
            let substituted = part
                .replacingOccurrences(of: "{EAN}", with: eanValue)
                .replacingOccurrences(of: "{REF}", with: ref)
            return NSRegularExpression.escapedPattern(for: substituted)
        }
        let regexBody = escapedParts.joined(separator: "(\\d+)")
        return try? NSRegularExpression(pattern: "^" + regexBody + "$")
    }
}
