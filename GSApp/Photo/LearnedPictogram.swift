import Foundation
import SwiftData

/// A pictogram the user has previously labelled. Holds a Vision
/// `VNFeaturePrintObservation` embedding (serialised to `Data`) so we
/// can match a freshly-cropped picto against the library via
/// nearest-neighbour distance, plus a thumbnail to confirm visually
/// in the annotation UI. Categories use the same six buckets as the
/// OCR flow (provenance / composition / care / standards /
/// restrictions / notes) so picto-derived text folds straight into
/// `extra.tech_views` on save.
@Model
final class LearnedPictogram {
    /// The user-assigned meaning, e.g. "Lavage à 30°", "Made in
    /// Italy", "Ne pas blanchir".
    var label: String
    /// Raw value of `TechViewCategory`. Stored as a string for
    /// schema-migration friendliness — SwiftData enums are still
    /// finicky around evolution.
    var categoryRawValue: String
    /// Serialised `VNFeaturePrintObservation` payload. Compared to
    /// other observations via `computeDistance(_:to:)`.
    var embedding: Data
    /// Small JPEG of the original crop. Mainly for the UI but also
    /// useful if we ever need to recompute embeddings after a Vision
    /// model update.
    var thumbnailData: Data
    var createdAt: Date
    /// Incremented each time this learned picto matches a freshly-
    /// captured candidate above the suggestion threshold.
    var matchCount: Int

    init(
        label: String,
        category: TechViewCategory,
        embedding: Data,
        thumbnailData: Data
    ) {
        self.label = label
        self.categoryRawValue = category.rawValue
        self.embedding = embedding
        self.thumbnailData = thumbnailData
        self.createdAt = .now
        self.matchCount = 0
    }

    var category: TechViewCategory? {
        TechViewCategory(rawValue: categoryRawValue)
    }
}
