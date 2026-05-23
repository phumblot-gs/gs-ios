import Foundation
import SwiftData

/// Per-candidate annotation state surfaced in the annotation UI:
/// what the user wants this picto to mean (`label`), which bucket
/// it belongs to (`category`), and — when we found one — a pointer
/// back to the learned picto that triggered the suggestion plus the
/// distance for tooltip / confidence display.
struct PictoAnnotation: Identifiable, Hashable {
    let id: UUID
    var label: String
    var category: TechViewCategory?
    var matchedLearnedID: PersistentIdentifier?
    var suggestionDistance: Float?

    var hasUsableContent: Bool {
        !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && category != nil
    }

    /// True when the user accepted a suggestion without editing.
    func reinforces(_ pictogram: LearnedPictogram) -> Bool {
        guard let matchedID = matchedLearnedID, matchedID == pictogram.persistentModelID else { return false }
        return label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            == pictogram.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
