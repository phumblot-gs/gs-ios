import SwiftUI
import UIKit

/// SwiftUI bridge over a UIScrollView-backed image viewer. Shown
/// on the validation step of the capture flow (Reprendre /
/// Enregistrer) so the user can:
///   - See the whole photo at once (aspect-fit by default, no
///     hidden parts on either side),
///   - Pinch-to-zoom up to 5× with the native iOS gesture,
///   - Pan around when zoomed in,
///   - Double-tap to toggle between fit and ~2.5× zoom centred on
///     the tap point — same convention as the iOS Photos app.
struct ZoomablePhotoView: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> ZoomableImageBox {
        let box = ZoomableImageBox()
        box.image = image
        return box
    }

    func updateUIView(_ view: ZoomableImageBox, context: Context) {
        if view.image !== image {
            view.image = image
        }
    }
}

/// UIKit-side implementation. Lives in its own class because
/// SwiftUI's `UIViewRepresentable` can't carry a delegate easily;
/// the scroll-view delegate has to be a long-lived NSObject.
final class ZoomableImageBox: UIView, UIScrollViewDelegate {
    var image: UIImage? {
        didSet {
            imageView.image = image
            setNeedsLayout()
        }
    }

    private let scrollView = UIScrollView()
    private let imageView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        scrollView.frame = bounds
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.delegate = self
        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = 5.0
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.bouncesZoom = true
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.backgroundColor = .black
        addSubview(scrollView)

        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        scrollView.addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(
            target: self,
            action: #selector(handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        fitImage()
    }

    /// Sizes the imageView so the image is aspect-fit inside the
    /// scrollView at zoom = 1, then recentres the content so any
    /// letterbox bands sit symmetrically.
    private func fitImage() {
        guard let image = imageView.image else { return }
        let bounds = scrollView.bounds.size
        guard bounds.width > 0, bounds.height > 0 else { return }
        let widthRatio = bounds.width / image.size.width
        let heightRatio = bounds.height / image.size.height
        let scale = min(widthRatio, heightRatio)
        let fitted = CGSize(
            width: image.size.width * scale,
            height: image.size.height * scale
        )
        imageView.frame = CGRect(origin: .zero, size: fitted)
        scrollView.contentSize = fitted
        // Reset zoom each time we re-fit (new image, rotation…)
        // so the user lands on the "see everything" state.
        scrollView.zoomScale = 1.0
        centerContent()
    }

    private func centerContent() {
        let xInset = max((scrollView.bounds.width - imageView.frame.width) / 2, 0)
        let yInset = max((scrollView.bounds.height - imageView.frame.height) / 2, 0)
        scrollView.contentInset = UIEdgeInsets(
            top: yInset,
            left: xInset,
            bottom: yInset,
            right: xInset
        )
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        if scrollView.zoomScale > 1.0 {
            scrollView.setZoomScale(1.0, animated: true)
        } else {
            let location = recognizer.location(in: imageView)
            let scale: CGFloat = 2.5
            let size = CGSize(
                width: scrollView.bounds.size.width / scale,
                height: scrollView.bounds.size.height / scale
            )
            let origin = CGPoint(
                x: location.x - size.width / 2,
                y: location.y - size.height / 2
            )
            scrollView.zoom(to: CGRect(origin: origin, size: size), animated: true)
        }
    }

    // MARK: - UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerContent()
    }
}
