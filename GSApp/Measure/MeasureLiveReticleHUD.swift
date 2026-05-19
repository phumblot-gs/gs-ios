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
                Rectangle().fill(.white).frame(width: 1.5, height: 14)
                Rectangle().fill(.white).frame(width: 14, height: 1.5)
            }
            .shadow(color: .black.opacity(0.35), radius: 1)

            Circle()
                .fill(pulse ? Color.green : centerDotColor)
                .frame(width: 6, height: 6)
                .shadow(color: .black.opacity(0.35), radius: 1)
        }
        .allowsHitTesting(false)
    }

    private var isProgressing: Bool {
        surface == .onSubject || surface == .onEdge
    }

    private var centerDotColor: Color {
        switch surface {
        case .onEdge:     return .orange
        case .onSubject:  return .white
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
