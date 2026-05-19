import Foundation
import SwiftData

/// One named measurement within a `MeasureCategory` — e.g. "manche" with
/// the labelled points [`col`, `emmanchure`, `bout de manche`]. The
/// distance for a captured measurement is the sum of the segments
/// between consecutive points.
@Model
final class MeasurementTemplate {
    var name: String
    /// Labels that guide the user when placing points on a new object,
    /// in placement order. Number of labels = number of points the user
    /// must place. A two-point measurement (`["col", "ourlet"]`) gives
    /// a single segment; three points give a chain of two segments.
    var pointLabels: [String]
    /// Position within the category's display order.
    var order: Int
    var category: MeasureCategory?

    init(name: String, pointLabels: [String], order: Int) {
        self.name = name
        self.pointLabels = pointLabels
        self.order = order
    }

    var pointCount: Int { pointLabels.count }
}
