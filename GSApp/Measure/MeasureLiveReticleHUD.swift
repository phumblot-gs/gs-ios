#if os(iOS)
import SwiftUI

/// 2D overlay rendered on top of the live AR view at the screen center.
/// Shows a crosshair, an inner dot, and an outer ring that fills
/// clockwise based on the stability score. The ring's tint reflects
/// the surface state — orange when the reticle hooks onto a product
/// edge, white on a flat subject region, and a red "X" when the
/// reticle isn't on the kept subject at all.
struct MeasureLiveReticleHUD: View {
    enum Surface: Equatable {
        case offTarget       // depth raycast valid, but outside the kept subject
        case noSurface       // no depth at all (sky, far wall, …)
        case onSubject
        case onEdge
    }

    let surface: Surface
    let stability: Float   // 0…1
    let pulse: Bool        // brief green flash right after a lock

    var body: some View {
        ZStack {
            // Outer guidance ring (faint, always visible)
            Circle()
                .stroke(.white.opacity(0.35), lineWidth: 1.5)
                .frame(width: 64, height: 64)

            if isProgressing {
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
            } else {
                // Off-target indicator — slashed circle in red.
                Image(systemName: "nosign")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.red.opacity(0.85))
                    .shadow(color: .black.opacity(0.35), radius: 1)
            }

            Group {
                Rectangle().fill(crosshairColor).frame(width: 1.5, height: 14)
                Rectangle().fill(crosshairColor).frame(width: 14, height: 1.5)
            }
            .shadow(color: crosshairShadow, radius: 1)

            Circle()
                .fill(pulse ? Color.green : centerDotColor)
                .frame(width: 6, height: 6)
                .shadow(color: crosshairShadow, radius: 1)
        }
        .allowsHitTesting(false)
    }

    private var isProgressing: Bool {
        surface == .onSubject || surface == .onEdge
    }

    /// Cross-hatch + centre-dot colour. Black when the disc behind it
    /// is white (`.onSubject`) so the user keeps a clear sight on the
    /// product edge they're aiming at; white in every other state
    /// because the disc is then red or yellow (off-target / edge) and
    /// the camera feed is the main contrast reference.
    private var crosshairColor: Color {
        surface == .onSubject ? .black : .white
    }

    /// Opposite-tone shadow so the cross stays visible on textured
    /// backgrounds: white halo for the black cross on the white disc,
    /// black halo elsewhere.
    private var crosshairShadow: Color {
        surface == .onSubject ? .white.opacity(0.45) : .black.opacity(0.35)
    }

    private var centerDotColor: Color {
        switch surface {
        case .onEdge:     return .orange
        case .onSubject:  return .black
        case .offTarget, .noSurface: return .white.opacity(0.5)
        }
    }

    private var ringColor: Color {
        // Yellow→orange at full stability on subject, orange→deep orange on edge.
        let t = Double(max(0, min(stability, 1)))
        switch surface {
        case .onEdge:
            return Color(red: 1, green: 0.55 - 0.2 * t, blue: 0.1 * (1 - t))
        default:
            return Color(red: 1, green: 1 - 0.15 * t, blue: 0.95 - 0.95 * t)
        }
    }
}
#endif
