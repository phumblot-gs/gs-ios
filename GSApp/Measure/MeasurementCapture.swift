#if os(iOS)
import Foundation
import simd

/// Result of capturing the world-space points for one measurement
/// (e.g. "sleeve", "chest"). The world points live in the ARKit world
/// coordinate system of the session they were captured in, so they
/// stay registered with the reference photo's `cameraTransform`.
struct MeasurementCapture: Identifiable, Hashable, Sendable {
    let id = UUID()
    let templateName: String
    let order: Int
    var worldPoints: [SIMD3<Float>]

    /// Chain distance in meters through every captured point.
    var meters: Float {
        guard worldPoints.count > 1 else { return 0 }
        var total: Float = 0
        for i in 1..<worldPoints.count {
            total += simd_distance(worldPoints[i - 1], worldPoints[i])
        }
        return total
    }

    var isComplete: Bool { worldPoints.count >= 2 }
}
#endif
