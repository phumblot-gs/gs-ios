import Foundation
import SwiftData

/// A user-defined category of measurable objects (e.g. "Robe", "Chemise",
/// "Boîte de jeu"). Holds the measurement schema for that category plus
/// optional Vision feature-print embedding so the app can suggest the
/// category when a similar object is presented later on.
@Model
final class MeasureCategory {
    var name: String
    var createdAt: Date
    /// Serialized `VNFeaturePrintObservation` data — used for nearest-
    /// neighbor suggestions on the next capture. Nil when no example
    /// image was retained on creation.
    var imageEmbedding: Data?
    /// Original example image (JPEG-encoded). Stored mostly for the
    /// category list UI thumbnail and as ground-truth in case we need to
    /// re-compute the embedding after a Vision model update.
    var exampleImageData: Data?

    @Relationship(deleteRule: .cascade, inverse: \MeasurementTemplate.category)
    var templates: [MeasurementTemplate] = []

    init(name: String, imageEmbedding: Data? = nil, exampleImageData: Data? = nil) {
        self.name = name
        self.createdAt = .now
        self.imageEmbedding = imageEmbedding
        self.exampleImageData = exampleImageData
    }
}
