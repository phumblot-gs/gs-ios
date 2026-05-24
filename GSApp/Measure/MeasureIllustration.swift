#if os(iOS)
import UIKit
import simd
import GSAPIClient

/// Renders the "illustration" snapshot of a measurement session:
/// the test product cut out onto a white background, each
/// measurement drawn as a coloured polyline connecting its world
/// points (reprojected onto the reference photo), the measurement
/// name placed centred on the segment, and a legend block below
/// the cutout listing each measurement with its converted value
/// in the user's chosen unit.
///
/// Used in two places:
///   - Creation flow → saved as `MeasureCategory.exampleImageData`
///     so the category list thumbnail shows the expected layout.
///   - Reference-bound flow → uploaded to GS as a tech-view photo
///     alongside the `extra.measures` payload.
enum MeasureIllustration {

    @MainActor
    static func render(
        cutout: UIImage,
        frame: CapturedFrame,
        captures: [MeasurementCapture],
        unit: DevSettings.MeasurementUnit
    ) -> UIImage {
        // The legend strip slots in below the cutout. Height
        // scales with the cutout's width so the text reads
        // sensibly on any aspect ratio.
        let cutoutSize = cutout.size
        let scaleRef = max(cutoutSize.width, cutoutSize.height)
        let legendRowHeight = max(scaleRef * 0.04, 32)
        let legendPadding = max(scaleRef * 0.025, 18)
        let legendRows = captures.filter { $0.worldPoints.count >= 2 }.count
        let legendHeight: CGFloat = legendRows > 0
            ? CGFloat(legendRows) * legendRowHeight + legendPadding * 2
            : 0

        let canvasSize = CGSize(
            width: cutoutSize.width,
            height: cutoutSize.height + legendHeight
        )

        let renderer = UIGraphicsImageRenderer(size: canvasSize)
        return renderer.image { ctx in
            let cgCtx = ctx.cgContext

            // White backdrop covers both the cutout and the
            // legend strip — the cutout itself was already
            // composited onto white upstream.
            UIColor.white.setFill()
            cgCtx.fill(CGRect(origin: .zero, size: canvasSize))
            cutout.draw(at: .zero)

            cgCtx.setLineCap(.round)
            cgCtx.setLineJoin(.round)

            // Build the segments + capture which captures have a
            // valid 2+ point set so the legend lines up with the
            // strokes.
            struct ResolvedCapture {
                let capture: MeasurementCapture
                let points: [CGPoint]
                let color: UIColor
            }
            var resolved: [ResolvedCapture] = []
            for (idx, capture) in captures.enumerated() where capture.worldPoints.count >= 2 {
                let color = palette[idx % palette.count]
                let pixelPoints: [CGPoint] = capture.worldPoints.compactMap { world in
                    guard let normalized = MeasureReprojection.projectToNormalized(
                        worldPoint: world,
                        frame: frame
                    ) else { return nil }
                    return CGPoint(
                        x: normalized.x * cutoutSize.width,
                        y: normalized.y * cutoutSize.height
                    )
                }
                guard pixelPoints.count >= 2 else { continue }
                resolved.append(.init(capture: capture, points: pixelPoints, color: color))

                // Segment path
                cgCtx.setStrokeColor(color.cgColor)
                cgCtx.setLineWidth(max(scaleRef * 0.005, 4))
                let path = CGMutablePath()
                path.move(to: pixelPoints[0])
                for p in pixelPoints.dropFirst() { path.addLine(to: p) }
                cgCtx.addPath(path)
                cgCtx.strokePath()

                // Endpoint discs
                let radius: CGFloat = max(scaleRef * 0.008, 7)
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
                    cgCtx.setLineWidth(max(scaleRef * 0.0025, 2))
                    cgCtx.strokeEllipse(in: rect)
                }
            }

            // Segment name labels, centred on each polyline's
            // midpoint. Drawn in the segment colour with a white
            // halo so they stay readable against the cutout AND
            // any segment colour underneath.
            let labelFontSize = max(scaleRef * 0.028, 18)
            let labelFont = UIFont.systemFont(ofSize: labelFontSize, weight: .semibold)
            for item in resolved {
                let mid = midpoint(item.points)
                drawHaloedText(
                    item.capture.templateName,
                    at: mid,
                    font: labelFont,
                    color: item.color,
                    in: cgCtx
                )
            }

            // Legend strip — "Name: value cm" rows.
            if legendRows > 0 {
                let legendTop = cutoutSize.height
                UIColor.white.setFill()
                cgCtx.fill(CGRect(
                    x: 0,
                    y: legendTop,
                    width: cutoutSize.width,
                    height: legendHeight
                ))
                // Thin separator line above the legend so the
                // strip reads as its own zone.
                cgCtx.setStrokeColor(UIColor.separator.cgColor)
                cgCtx.setLineWidth(max(scaleRef * 0.002, 1))
                cgCtx.beginPath()
                cgCtx.move(to: CGPoint(x: legendPadding, y: legendTop))
                cgCtx.addLine(to: CGPoint(x: cutoutSize.width - legendPadding, y: legendTop))
                cgCtx.strokePath()

                let legendFontSize = max(scaleRef * 0.026, 18)
                let legendFont = UIFont.systemFont(ofSize: legendFontSize, weight: .medium)
                let valueFont = UIFont.monospacedDigitSystemFont(ofSize: legendFontSize, weight: .regular)
                for (idx, item) in resolved.enumerated() {
                    let rowY = legendTop + legendPadding + CGFloat(idx) * legendRowHeight
                    let swatchSize = legendFontSize * 0.6
                    let swatchRect = CGRect(
                        x: legendPadding,
                        y: rowY + (legendRowHeight - swatchSize) / 2 - swatchSize / 2,
                        width: swatchSize,
                        height: swatchSize
                    )
                    cgCtx.setFillColor(item.color.cgColor)
                    cgCtx.fillEllipse(in: swatchRect)

                    let nameOrigin = CGPoint(
                        x: swatchRect.maxX + swatchSize * 0.6,
                        y: rowY
                    )
                    let name = item.capture.templateName
                    (name as NSString).draw(
                        at: nameOrigin,
                        withAttributes: [
                            .font: legendFont,
                            .foregroundColor: UIColor.darkText
                        ]
                    )

                    let valueText = format(item.capture.meters, unit: unit)
                    let valueAttr: [NSAttributedString.Key: Any] = [
                        .font: valueFont,
                        .foregroundColor: UIColor.darkText
                    ]
                    let valueSize = (valueText as NSString).size(withAttributes: valueAttr)
                    let valueOrigin = CGPoint(
                        x: cutoutSize.width - legendPadding - valueSize.width,
                        y: rowY
                    )
                    (valueText as NSString).draw(at: valueOrigin, withAttributes: valueAttr)
                }
            }
        }
    }

    // MARK: - Helpers

    private static func midpoint(_ points: [CGPoint]) -> CGPoint {
        // For a polyline, walk total length and find the point at
        // half-length. Falls back to the geometric centre for 2-pt
        // segments (which is exactly the midpoint anyway).
        guard points.count >= 2 else { return points.first ?? .zero }
        if points.count == 2 {
            return CGPoint(
                x: (points[0].x + points[1].x) / 2,
                y: (points[0].y + points[1].y) / 2
            )
        }
        var totalLength: CGFloat = 0
        for i in 1..<points.count {
            totalLength += distance(points[i - 1], points[i])
        }
        let target = totalLength / 2
        var travelled: CGFloat = 0
        for i in 1..<points.count {
            let segLen = distance(points[i - 1], points[i])
            if travelled + segLen >= target {
                let t = (target - travelled) / max(segLen, 0.0001)
                let a = points[i - 1]
                let b = points[i]
                return CGPoint(
                    x: a.x + (b.x - a.x) * t,
                    y: a.y + (b.y - a.y) * t
                )
            }
            travelled += segLen
        }
        return points.last ?? .zero
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    private static func drawHaloedText(
        _ text: String,
        at center: CGPoint,
        font: UIFont,
        color: UIColor,
        in cgContext: CGContext
    ) {
        let size = (text as NSString).size(withAttributes: [.font: font])
        let origin = CGPoint(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2
        )
        // White halo: render the text with a fat white stroke,
        // then the filled colour on top.
        (text as NSString).draw(at: origin, withAttributes: [
            .font: font,
            .foregroundColor: color,
            .strokeColor: UIColor.white,
            .strokeWidth: -font.pointSize * 0.4
        ])
    }

    private static func format(_ meters: Float, unit: DevSettings.MeasurementUnit) -> String {
        let value = unit.convert(meters: Double(meters))
        return String(format: "%.1f %@", value, unit.apiSymbol)
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
