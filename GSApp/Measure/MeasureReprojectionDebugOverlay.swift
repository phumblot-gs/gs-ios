#if os(iOS)
import SwiftUI
import simd
import GSAPIClient

/// Debug thumbnail rendered on top of the placement view. Stacks:
///   1. The reference photo at small size in a corner.
///   2. The rasterized `SubjectMaskGrid` over it — green for `.subject`,
///      orange for `.edge`, transparent elsewhere.
///   3. A red dot at the projected position of the current world point.
///
/// Tells us in one glance whether the reticle's reprojection lands
/// inside the mask (the gating would pass) or beside it (gating fails).
/// Also surfaces "behind the camera" cases where the reprojection
/// returns nil — the dot just doesn't show.
struct MeasureReprojectionDebugOverlay: View {
    let referenceFrame: CapturedFrame
    let maskImage: UIImage?
    let worldPosition: SIMD3<Float>?

    private let thumbnailWidth: CGFloat = 140

    private var thumbnailSize: CGSize {
        let aspect = referenceFrame.image.size.width / referenceFrame.image.size.height
        return CGSize(width: thumbnailWidth, height: thumbnailWidth / aspect)
    }

    private var reprojectedPoint: CGPoint? {
        guard let worldPosition,
              let n = MeasureReprojection.projectToNormalized(
                worldPoint: worldPosition,
                frame: referenceFrame
              ) else { return nil }
        return n
    }

    var body: some View {
        ZStack {
            Image(uiImage: referenceFrame.image)
                .resizable()
                .scaledToFit()

            if let maskImage {
                Image(uiImage: maskImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            }

            if let p = reprojectedPoint {
                Circle()
                    .fill(.red)
                    .frame(width: 9, height: 9)
                    .overlay(Circle().stroke(.white, lineWidth: 1.5))
                    .position(
                        x: p.x * thumbnailSize.width,
                        y: p.y * thumbnailSize.height
                    )
            } else {
                // Reprojection returned nil (point behind the reference
                // camera) — surface this so we don't think the gating
                // is just lazy.
                Text("nil")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.red, in: Capsule())
            }
        }
        .frame(width: thumbnailSize.width, height: thumbnailSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.white.opacity(0.5), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 3)
    }
}
#endif
