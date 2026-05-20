import Foundation
import SwiftData

/// One named measurement within a `MeasureCategory` — e.g. "manche".
/// The number of points is decided when the category is FIRST created
/// using a "test" product (the user places however many points they
/// want during placement; the count is then frozen as the template's
/// `pointCount`). Subsequent measurements of products in this category
/// require the same number of points.
@Model
final class MeasurementTemplate {
    var name: String
    /// Position within the category's display order.
    var order: Int
    /// Number of points the user placed during category creation.
    /// 2 by default for templates created before this field existed
    /// (early-dev migration: reinstall, but the model still reads).
    var pointCount: Int = 2
    var category: MeasureCategory?

    init(name: String, order: Int, pointCount: Int = 2) {
        self.name = name
        self.order = order
        self.pointCount = pointCount
    }
}
