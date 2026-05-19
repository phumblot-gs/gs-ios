#if os(iOS)
import SwiftUI

/// 2D overlay rendered on top of the live AR view at the screen center.
/// Shows a crosshair, an inner dot, and an outer ring that fills
/// clockwise based on the stability score. When the score hits 1 and
/// the device stays still, the underlying coordinator locks the point;
/// at that moment we briefly flash the reticle green.
struct MeasureLiveReticleHUD: View {
    /// 0…1 stability score from the coordinator. -1 marks an
    /// unreachable spot (no depth, no surface).
    let stability: Float
    /// Set to `true` for ~150 ms right after a point locks, so the user
    /// gets visual confirmation alongside the system sound + haptic.
    let pulse: Bool

    var body: some View {
        ZStack {
            // Outer guidance ring (faint, always visible)
            Circle()
                .stroke(.white.opacity(0.35), lineWidth: 1.5)
                .frame(width: 64, height: 64)

            // Stability ring — fills clockwise from 12 o'clock
            Circle()
                .trim(from: 0, to: CGFloat(max(0, min(stability, 1))))
                .stroke(
                    pulse ? Color.green : ringColor,
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )
                .frame(width: 64, height: 64)
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.1), value: stability)
                .animation(.easeOut(duration: 0.15), value: pulse)

            // Crosshair
            Group {
                Rectangle().fill(.white).frame(width: 1.5, height: 14)
                Rectangle().fill(.white).frame(width: 14, height: 1.5)
            }
            .shadow(color: .black.opacity(0.35), radius: 1)

            // Center dot
            Circle()
                .fill(pulse ? Color.green : Color.white)
                .frame(width: 6, height: 6)
                .shadow(color: .black.opacity(0.35), radius: 1)
        }
        .allowsHitTesting(false)
    }

    private var ringColor: Color {
        // Bright yellow at full stability, white at zero.
        let t = Double(max(0, min(stability, 1)))
        return Color(
            red: 1,
            green: 1 - 0.15 * t,
            blue: 0.95 - 0.95 * t
        )
    }
}
#endif
