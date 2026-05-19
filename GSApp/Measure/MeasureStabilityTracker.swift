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

    /// Per-surface tunables. The coordinator switches profiles based
    /// on whether the reticle is on a flat subject region or hugging
    /// a product edge — edges need to lock faster + tolerate less
    /// jitter so the user can confidently mark the border.
    struct Profile {
        let windowSamples: Int
        let positionVarianceCeiling: Float   // m² (variance, not RMS)
        let rotationRateCeiling: Double      // rad/s
        let lockScore: Float                 // 0…1 — combined score that counts as "ready"
        let lockHoldFrames: Int              // consecutive ready frames before commit

        /// Default subject profile — generous enough that natural hand
        /// hold reaches 100 % within ~0.4 s of pointing.
        static let subject = Profile(
            windowSamples: 18,
            positionVarianceCeiling: 2.5e-5,   // ~5 mm RMS
            rotationRateCeiling: 0.55,         // ~31 °/s
            lockScore: 0.82,
            lockHoldFrames: 10
        )
        /// Edge profile — tighter variance (we want a clean grip), but
        /// commits a third faster so the user feels the snap.
        static let edge = Profile(
            windowSamples: 14,
            positionVarianceCeiling: 1.2e-5,   // ~3.5 mm RMS
            rotationRateCeiling: 0.45,
            lockScore: 0.75,
            lockHoldFrames: 6
        )
    }

    private var profile: Profile = .subject

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

    /// Switch the profile used to score subsequent observations. Resets
    /// the hold counter — we don't want a partially-charged lock from
    /// the previous profile to spill into the new one.
    func setProfile(_ profile: Profile) {
        if self.profile.windowSamples != profile.windowSamples {
            // Trim the buffer to the new window so the next score uses
            // the correct sample count.
            while positions.count > profile.windowSamples { positions.removeFirst() }
            while rotationRates.count > profile.windowSamples { rotationRates.removeFirst() }
        }
        self.profile = profile
        holdCount = 0
    }

    /// Push a new reticle position. Returns the latest stability score
    /// in [0, 1] and a flag indicating the point has locked.
    func observe(position: SIMD3<Float>) -> (stability: Float, locked: Bool) {
        positions.append(position)
        if positions.count > profile.windowSamples { positions.removeFirst() }

        let rate = motion.deviceMotion.map { motion in
            let r = motion.rotationRate
            return sqrt(r.x * r.x + r.y * r.y + r.z * r.z)
        } ?? 0
        rotationRates.append(rate)
        if rotationRates.count > profile.windowSamples { rotationRates.removeFirst() }

        guard positions.count == profile.windowSamples else {
            return (0, false)
        }

        let positionScore = positionStability()
        let motionScore = motionStability()
        let combined = min(positionScore, motionScore)

        if combined >= profile.lockScore {
            holdCount += 1
        } else {
            holdCount = 0
        }
        let locked = holdCount >= profile.lockHoldFrames
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
        if variance >= profile.positionVarianceCeiling { return 0 }
        return 1 - variance / profile.positionVarianceCeiling
    }

    private func motionStability() -> Float {
        let mean = rotationRates.reduce(0, +) / Double(rotationRates.count)
        if mean >= profile.rotationRateCeiling { return 0 }
        return Float(1 - mean / profile.rotationRateCeiling)
    }
}
#endif
