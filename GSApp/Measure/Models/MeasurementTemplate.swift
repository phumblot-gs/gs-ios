import Foundation
import SwiftData

/// One named measurement within a `MeasureCategory` — e.g. "manche".
/// The number of points is decided at capture time per object (some
/// sleeves are best measured with 2 points, others need 3 to follow
/// the curve), so the template carries only the semantic name plus its
/// display order; the geometry is free.
@Model
final class MeasurementTemplate {
    var name: String
    /// Position within the category's display order.
    var order: Int
    var category: MeasureCategory?

    init(name: String, order: Int) {
        self.name = name
        self.order = order
    }
}
