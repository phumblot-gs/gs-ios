#if os(iOS)
import UIKit
import simd

/// Renders the "illustration" snapshot of a freshly-created
/// `MeasureCategory`: the test product cut out onto a white
/// background, with each measurement drawn as a coloured polyline
/// connecting its world points (reprojected onto the reference
/// photo). Saved as JPEG into `MeasureCategory.exampleImageData`
/// so the category list thumbnail shows where the user expects to
/// place the points the next time.
enum MeasureIllustration {

    @MainActor
    static func render(
        cutout: UIImage,
        frame: CapturedFrame,
        captures: [MeasurementCapture]
    ) -> UIImage {
        let size = cutout.size
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            cutout.draw(at: .zero)
            let cgCtx = ctx.cgContext
            cgCtx.setLineCap(.round)
            cgCtx.setLineJoin(.round)

            for (idx, capture) in captures.enumerated() where capture.worldPoints.count >= 2 {
                let color = palette[idx % palette.count]
                let pixelPoints: [CGPoint] = capture.worldPoints.compactMap { world in
                    guard let normalized = MeasureReprojection.projectToNormalized(
                        worldPoint: world,
                        frame: frame
                    ) else { return nil }
                    return CGPoint(
                        x: normalized.x * size.width,
                        y: normalized.y * size.height
                    )
                }
                guard pixelPoints.count >= 2 else { continue }

                // Segment path
                cgCtx.setStrokeColor(color.cgColor)
                cgCtx.setLineWidth(6)
                let path = CGMutablePath()
                path.move(to: pixelPoints[0])
                for p in pixelPoints.dropFirst() { path.addLine(to: p) }
                cgCtx.addPath(path)
                cgCtx.strokePath()

                // Endpoint discs (filled color with a white border so
                // they pop on a white background)
                let radius: CGFloat = 9
                for p in pixelPoints {
                    let rect = CGRect(
                        x: p.x - radius,
                        y: p.y - radius,
                        width: radius * 2,
                        height: radius * 2
                    )
                    cgCtx.setFillColor(color.cgColor)
                    cgCtx.fillEllipse(in: rect)
                    cgCtx.setStrokeColor(UIColor.white.cgColor)
                    cgCtx.setLineWidth(2.5)
                    cgCtx.strokeEllipse(in: rect)
                }
            }
        }
    }

    /// Same palette the live 3D overlay uses, so the illustration
    /// matches what the user saw during placement.
    private static let palette: [UIColor] = [
        .systemGreen,
        .systemCyan,
        .systemPink,
        .systemOrange,
        .systemPurple
    ]
}
#endif
