#if os(iOS)
import UIKit
import QuartzCore

/// Lightweight overlay that sits on top of the camera preview and renders:
///   - a fine green underline above each detected 1D barcode
///   - four green L-shaped corner brackets around each detected 2D code
///   - a thin "+" crosshair pinned to the center of the screen
///
/// One CAShapeLayer per visual element, recycled across frames. We aim for
/// 30 fps redraws so the overlay tracks codes smoothly as the user
/// repositions the device.
final class ScannerOverlayView: UIView {

    private let crosshairLayer = CAShapeLayer()

    /// One sub-layer per currently visible highlight (1D underline or 2D
    /// corner bracket set). Keyed by the payload string so we can retire
    /// stale entries that haven't been seen for a few frames.
    private var highlightLayers: [String: CAShapeLayer] = [:]

    /// How long a highlight stays visible after its last detection frame.
    /// Tuned to feel "live" without flickering when the recogniser briefly
    /// misses a frame.
    private let highlightTTL: TimeInterval = 0.3
    private var lastSeen: [String: Date] = [:]

    private let strokeColor = UIColor.systemGreen.cgColor
    private let crosshairColor = UIColor.white.withAlphaComponent(0.75).cgColor

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        configureCrosshair()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateCrosshairPath()
    }

    // MARK: - Public API

    /// Replace the current set of highlights with `highlights`. Anything not
    /// in the new set but seen recently keeps drawing for a short TTL.
    func updateHighlights(_ highlights: [Highlight]) {
        let now = Date()
        for h in highlights {
            lastSeen[h.payload] = now
            let layer = highlightLayers[h.payload] ?? makeHighlightLayer(for: h.payload)
            layer.path = h.isOneDimensional ? path1D(for: h) : path2D(for: h)
        }
        // Retire stale highlights.
        for (payload, layer) in highlightLayers {
            if let seen = lastSeen[payload], now.timeIntervalSince(seen) > highlightTTL {
                layer.removeFromSuperlayer()
                highlightLayers.removeValue(forKey: payload)
                lastSeen.removeValue(forKey: payload)
            }
        }
    }

    func clearAll() {
        for layer in highlightLayers.values {
            layer.removeFromSuperlayer()
        }
        highlightLayers.removeAll()
        lastSeen.removeAll()
    }

    // MARK: - Private

    private func makeHighlightLayer(for payload: String) -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.fillColor = UIColor.clear.cgColor
        layer.strokeColor = strokeColor
        layer.lineWidth = 3
        layer.lineJoin = .round
        layer.lineCap = .round
        layer.shadowColor = strokeColor
        layer.shadowOffset = .zero
        layer.shadowRadius = 4
        layer.shadowOpacity = 0.6
        self.layer.addSublayer(layer)
        highlightLayers[payload] = layer
        return layer
    }

    /// Build a "laser line" that goes through the centre of the barcode along
    /// its long axis — i.e. from the first bar to the last bar, perpendicular
    /// to the bars themselves. Works the same whether the code is held
    /// upright, sideways, tilted, or upside-down.
    ///
    /// We don't rely on AVFoundation's corner ordering (which empirically
    /// disagrees with the docs depending on rotation): we measure the length
    /// of two adjacent edges and treat the shorter pair as the "short" edges
    /// — the ones running along the bars. The midpoints of those short edges
    /// joined together give the long-axis centreline regardless of the
    /// underlying corner order.
    private func path1D(for h: Highlight) -> CGPath {
        let path = CGMutablePath()
        guard h.corners.count == 4 else { return path }
        let c = h.corners

        let edge01 = distance(c[0], c[1])
        let edge12 = distance(c[1], c[2])

        // The shorter pair of adjacent edges runs along the bars. The midpoints
        // of those two short edges define the long-axis centreline (perpendicular
        // to the bars, full code length).
        let (a, b): (CGPoint, CGPoint)
        if edge01 < edge12 {
            a = midpoint(c[0], c[1])
            b = midpoint(c[2], c[3])
        } else {
            a = midpoint(c[1], c[2])
            b = midpoint(c[3], c[0])
        }
        path.move(to: a)
        path.addLine(to: b)
        return path
    }

    private func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }

    /// Build four L-shaped corner brackets, one at each corner of the QR /
    /// data-matrix bounding quad. The arms are 15% of the average side
    /// length, never larger than 24 pt.
    private func path2D(for h: Highlight) -> CGPath {
        let path = CGMutablePath()
        guard h.corners.count == 4 else { return path }
        let armLength: CGFloat = {
            let side = max(
                distance(h.corners[0], h.corners[1]),
                distance(h.corners[1], h.corners[2])
            )
            return min(24, max(8, side * 0.15))
        }()
        // corners order: TL, TR, BR, BL (AVMetadata convention)
        let neighbours: [(Int, [Int])] = [
            (0, [1, 3]),  // top-left has neighbours TR and BL
            (1, [0, 2]),
            (2, [1, 3]),
            (3, [0, 2])
        ]
        for (cornerIndex, n) in neighbours {
            let corner = h.corners[cornerIndex]
            for neighbourIndex in n {
                let neighbour = h.corners[neighbourIndex]
                let endpoint = interpolate(from: corner, to: neighbour, distance: armLength)
                path.move(to: corner)
                path.addLine(to: endpoint)
            }
        }
        return path
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(b.x - a.x, b.y - a.y)
    }

    private func interpolate(from a: CGPoint, to b: CGPoint, distance d: CGFloat) -> CGPoint {
        let total = distance(a, b)
        guard total > 0 else { return a }
        let t = d / total
        return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    // MARK: - Crosshair

    private func configureCrosshair() {
        crosshairLayer.strokeColor = crosshairColor
        crosshairLayer.lineWidth = 1
        crosshairLayer.fillColor = UIColor.clear.cgColor
        crosshairLayer.lineCap = .round
        layer.addSublayer(crosshairLayer)
    }

    private func updateCrosshairPath() {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let arm: CGFloat = 12
        let path = CGMutablePath()
        path.move(to: CGPoint(x: center.x - arm, y: center.y))
        path.addLine(to: CGPoint(x: center.x + arm, y: center.y))
        path.move(to: CGPoint(x: center.x, y: center.y - arm))
        path.addLine(to: CGPoint(x: center.x, y: center.y + arm))
        crosshairLayer.path = path
    }
}

struct Highlight {
    let payload: String
    let isOneDimensional: Bool
    let corners: [CGPoint]  // in overlay view coordinates, length 4
}
#endif
