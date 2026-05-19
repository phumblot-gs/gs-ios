import Foundation
import SwiftData

/// A user-defined category of measurable objects (e.g. "Robe", "Chemise",
/// "Boîte de jeu"). Holds the measurement schema for that category plus
/// optional Vision feature-print embedding so the app can suggest the
/// category when a similar object is presented later on.
@Model
final class MeasureCategory {
    var name: String
    /// Optional identifier used to map the category onto a third-party
    /// system's codification (e.g. an internal ERP code). Free-form
    /// string; not validated.
    var code: String?
    /// Optional link to a Grand Shooting catalog `category_id`. When set,
    /// the GS category list is the source of truth — at app launch we
    /// validate the link against the freshly-pulled catalog and clear
    /// dangling ids (with a heads-up alert).
    var gsCategoryID: Int?
    var createdAt: Date
    /// Serialized `VNFeaturePrintObservation` data — used for nearest-
    /// neighbor suggestions on the next capture. Nil when no example
    /// image was retained on creation.
    var imageEmbedding: Data?
    /// Original example image (JPEG-encoded). Stored mostly for the
    /// category list UI thumbnail and as ground-truth in case we need
    /// to re-compute the embedding after a Vision model update.
    var exampleImageData: Data?

    @Relationship(deleteRule: .cascade, inverse: \MeasurementTemplate.category)
    var templates: [MeasurementTemplate] = []

    init(
        name: String,
        code: String? = nil,
        gsCategoryID: Int? = nil,
        imageEmbedding: Data? = nil,
        exampleImageData: Data? = nil
    ) {
        self.name = name
        self.code = code
        self.gsCategoryID = gsCategoryID
        self.createdAt = .now
        self.imageEmbedding = imageEmbedding
        self.exampleImageData = exampleImageData
    }
}
