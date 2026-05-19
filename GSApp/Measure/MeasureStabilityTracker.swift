#if os(iOS)
import Foundation
import simd
import CoreMotion

/// Sliding-window stability detector for the live AR reticle.
/// Watches the reticle's world position over a short window and reports
/// a 0…1 "stability" score. When stability hits 1, the caller locks the
/// point.
///
/// Two signals are fused:
///   1. **Position variance** — how much the reticle's world position
///      has wandered over the last N samples. Tight grouping → stable.
///   2. **Device motion** — gyroscope rotation rate over the same
///      window. Holding the device still → stable.
@MainActor
final class MeasureStabilityTracker {

    /// Tunable thresholds. Values picked empirically; if either side
    /// dominates we'd surface them to settings.
    private let windowSamples = 18                  // ≈300 ms at 60 fps
    private let positionVarianceCeiling: Float = 9e-6   // ~3 mm RMS
    private let rotationRateCeiling: Double = 0.35      // rad/s
    private let lockHoldFrames = 12                 // ~200 ms of "ready"

    private var positions: [SIMD3<Float>] = []
    private var rotationRates: [Double] = []
    private var holdCount = 0
    // CMMotionManager is thread-safe in practice; nonisolated(unsafe)
    // is the standard escape hatch under Swift 6 strict concurrency
    // for sensor managers that don't have Sendable conformance.
    nonisolated(unsafe) private let motion = CMMotionManager()

    init() {
        motion.deviceMotionUpdateInterval = 1.0 / 60.0
        if motion.isDeviceMotionAvailable {
            motion.startDeviceMotionUpdates()
        }
    }

    deinit {
        motion.stopDeviceMotionUpdates()
    }

    func reset() {
        positions.removeAll()
        rotationRates.removeAll()
        holdCount = 0
    }

    /// Push a new reticle position. Returns the latest stability score
    /// in [0, 1] and a flag indicating the point has locked.
    func observe(position: SIMD3<Float>) -> (stability: Float, locked: Bool) {
        positions.append(position)
        if positions.count > windowSamples { positions.removeFirst() }

        let rate = motion.deviceMotion.map { motion in
            let r = motion.rotationRate
            return sqrt(r.x * r.x + r.y * r.y + r.z * r.z)
        } ?? 0
        rotationRates.append(rate)
        if rotationRates.count > windowSamples { rotationRates.removeFirst() }

        guard positions.count == windowSamples else {
            return (0, false)
        }

        let positionScore = positionStability()
        let motionScore = motionStability()
        let combined = min(positionScore, motionScore)

        if combined >= 1.0 {
            holdCount += 1
        } else {
            holdCount = 0
        }
        let locked = holdCount >= lockHoldFrames
        if locked { reset() }
        return (combined, locked)
    }

    /// Average of the last window. Used as the locked point so a tiny
    /// jitter doesn't bias toward the very last sample.
    var averagedPosition: SIMD3<Float>? {
        guard !positions.isEmpty else { return nil }
        var acc = SIMD3<Float>(repeating: 0)
        for p in positions { acc += p }
        return acc / Float(positions.count)
    }

    private func positionStability() -> Float {
        guard let mean = averagedPosition else { return 0 }
        var sumSq: Float = 0
        for p in positions {
            let d = p - mean
            sumSq += simd_length_squared(d)
        }
        let variance = sumSq / Float(positions.count)
        if variance >= positionVarianceCeiling { return 0 }
        return 1 - variance / positionVarianceCeiling
    }

    private func motionStability() -> Float {
        let mean = rotationRates.reduce(0, +) / Double(rotationRates.count)
        if mean >= rotationRateCeiling { return 0 }
        return Float(1 - mean / rotationRateCeiling)
    }
}
#endif
