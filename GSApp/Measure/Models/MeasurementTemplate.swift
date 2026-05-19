import Foundation
import SwiftData

/// One named measurement within a `MeasureCategory` — e.g. "manche". The
/// distance recorded for the measurement is the sum of the segments
/// between `pointCount` points placed sequentially by the user. Points
/// themselves carry no labels: only the measurement does.
@Model
final class MeasurementTemplate {
    var name: String
    /// How many points the user is asked to place to compute this
    /// measurement. Minimum 2 (one segment); chain of N points gives
    /// `N − 1` segments summed.
    var pointCount: Int
    /// Position within the category's display order.
    var order: Int
    var category: MeasureCategory?

    init(name: String, pointCount: Int = 2, order: Int) {
        self.name = name
        self.pointCount = max(2, pointCount)
        self.order = order
    }
}
