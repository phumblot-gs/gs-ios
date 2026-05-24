import SwiftUI

/// Full-screen viewer for a thumbnail. Takes a remote URL (from
/// the GS CDN) and/or local JPEG bytes (for just-uploaded shots
/// whose CDN thumbnail is still being generated). Designed to be
/// presented with `.matchedTransitionSource(id:in:)` on the source
/// + `.navigationTransition(.zoom(sourceID:in:))` on the
/// destination, so the thumbnail visually expands into full-screen.
///
/// Supports pinch-to-zoom, drag-to-pan when zoomed in, double-tap
/// to toggle 1×↔2.5×, and a tap on the close button to dismiss.
/// Pull-to-dismiss is handled natively by `fullScreenCover`'s
/// zoom transition when scale == 1.
struct PictureZoomView: View {
    let imageURL: URL?
    /// JPEG bytes available locally (just-uploaded picture or
    /// ghost preview that hasn't reached GS yet). When set, used
    /// as a fallback while the CDN URL loads (or as the only
    /// source if `imageURL` is nil).
    let localData: Data?
    let onDismiss: () -> Void

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            zoomableContent
                .scaleEffect(scale)
                .offset(offset)
                .gesture(zoomGesture)
                .simultaneousGesture(panGesture)
                .onTapGesture(count: 2, perform: toggleZoom)

            VStack {
                HStack {
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 32))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.45))
                    }
                    .padding(.top, 8)
                    .padding(.trailing, 16)
                }
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var zoomableContent: some View {
        if let url = imageURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFit()
                case .failure:
                    localOrMissing
                case .empty:
                    if localData != nil {
                        localOrMissing
                    } else {
                        ProgressView().tint(.white)
                    }
                @unknown default:
                    ProgressView().tint(.white)
                }
            }
        } else {
            localOrMissing
        }
    }

    @ViewBuilder
    private var localOrMissing: some View {
        if let localData, let ui = UIImage(data: localData) {
            Image(uiImage: ui).resizable().scaledToFit()
        } else {
            Image(systemName: "photo")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
        }
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = max(1, min(lastScale * value.magnification, 5))
            }
            .onEnded { _ in
                lastScale = scale
                if scale <= 1 {
                    withAnimation(.spring) {
                        scale = 1
                        lastScale = 1
                        offset = .zero
                        lastOffset = .zero
                    }
                }
            }
    }

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1 else { return }
                offset = CGSize(
                    width: lastOffset.width + value.translation.width,
                    height: lastOffset.height + value.translation.height
                )
            }
            .onEnded { _ in
                lastOffset = offset
            }
    }

    private func toggleZoom() {
        withAnimation(.spring) {
            if scale > 1 {
                scale = 1
                lastScale = 1
                offset = .zero
                lastOffset = .zero
            } else {
                scale = 2.5
                lastScale = 2.5
            }
        }
    }
}
