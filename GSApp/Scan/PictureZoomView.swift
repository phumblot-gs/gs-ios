import SwiftUI

/// Process-wide image cache for the carousel. SwiftUI's
/// `AsyncImage` doesn't keep decoded images in memory, so
/// navigating through pages re-fetches each time and flashes a
/// placeholder. This `NSCache` keeps the decoded `UIImage`s
/// keyed by URL — second visits paint instantly.
final class ZoomImageCache: @unchecked Sendable {
    static let shared = ZoomImageCache()
    private let cache = NSCache<NSURL, UIImage>()

    private init() {
        cache.countLimit = 60   // ~25 thumbnails * 3 buckets
    }

    func image(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    func store(_ image: UIImage, for url: URL) {
        cache.setObject(image, forKey: url as NSURL)
    }
}

/// AsyncImage replacement backed by `ZoomImageCache`. Renders
/// from cache when available; otherwise fetches via URLSession,
/// caches the decoded image and renders it. While loading, shows
/// a spinner — but jumping back to an already-fetched URL
/// (e.g. tapping a page indicator dot) is instant.
struct CachedRemoteImage: View {
    let url: URL
    let fallbackData: Data?

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else if failed, let fallbackData, let ui = UIImage(data: fallbackData) {
                Image(uiImage: ui).resizable().scaledToFit()
            } else if failed {
                Image(systemName: "photo")
                    .font(.system(size: 60))
                    .foregroundStyle(.secondary)
            } else if let fallbackData, let ui = UIImage(data: fallbackData) {
                // Paint the local copy while the CDN one loads,
                // so swiping onto a just-uploaded picture isn't
                // a blank black frame.
                Image(uiImage: ui).resizable().scaledToFit()
            } else {
                ProgressView().tint(.white)
            }
        }
        .task(id: url) {
            if let cached = ZoomImageCache.shared.image(for: url) {
                image = cached
                return
            }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard !Task.isCancelled else { return }
                if let decoded = UIImage(data: data) {
                    ZoomImageCache.shared.store(decoded, for: url)
                    image = decoded
                } else {
                    failed = true
                }
            } catch {
                if !Task.isCancelled { failed = true }
            }
        }
    }
}

/// One viewable thumbnail — either a GS-backed `Picture` (which
/// gives us a CDN URL) or a still-uploading ghost (only local
/// JPEG bytes). The `id` is the stable `matchedTransitionSource`
/// key on the originating thumbnail.
struct ZoomableItem: Identifiable, Hashable {
    let id: String
    /// `smalltext` for GS-backed rows, the local upload filename
    /// for ghosts. Rendered under the image so the user knows
    /// what they're looking at.
    let filename: String?
    let imageURL: URL?
    let localData: Data?
}

/// Snapshot handed to the full-screen cover when the user taps a
/// thumbnail. Carries the full ordered list of siblings in the
/// originating bucket (Measures / Labels / Tech views) so the
/// user can swipe between them.
struct ZoomPresentation: Identifiable, Hashable {
    let items: [ZoomableItem]
    let startIndex: Int

    /// Identifies the presentation by the initially-tapped item.
    /// Used by `.fullScreenCover(item:)` to detect new
    /// presentations vs. updates of the same one.
    var id: String {
        guard items.indices.contains(startIndex) else { return "empty" }
        return items[startIndex].id
    }
}

/// Full-screen carousel for the reference detail's thumbnails.
/// Horizontal swipe pages between siblings; each page supports
/// pinch-to-zoom, double-tap toggle, and pan-when-zoomed. A
/// monospaced filename pill sits at the bottom of every page so
/// the user can identify the shot.
///
/// Presented via `.fullScreenCover(item: $zoomPresentation)`. The
/// originating thumbnail uses
/// `.matchedTransitionSource(id: item.id, in: namespace)`; the
/// destination's `.navigationTransition(.zoom(sourceID:in:))`
/// matches the **starting** item only — swiping then dismissing
/// from a different page falls back to a standard slide.
struct PictureZoomView: View {
    let items: [ZoomableItem]
    let onDismiss: () -> Void

    @State private var currentIndex: Int

    init(items: [ZoomableItem], startIndex: Int, onDismiss: @escaping () -> Void) {
        self.items = items
        self._currentIndex = State(initialValue: min(max(startIndex, 0), max(items.count - 1, 0)))
        self.onDismiss = onDismiss
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // TabView's `.page` style gives us the carousel
            // gestures + a dot indicator for free. Each page
            // owns its own zoom state (see `ZoomablePage`).
            TabView(selection: $currentIndex) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    ZoomablePage(item: item)
                        .tag(idx)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: items.count > 1 ? .always : .never))
            .indexViewStyle(.page(backgroundDisplayMode: .interactive))

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
                filenameBadge
            }
        }
    }

    /// Monospaced pill at the bottom showing the current page's
    /// filename (smalltext / upload name). Hidden when the
    /// current item has no filename for some reason.
    @ViewBuilder
    private var filenameBadge: some View {
        if items.indices.contains(currentIndex),
           let filename = items[currentIndex].filename {
            Text(filename)
                .font(.caption.monospaced())
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.black.opacity(0.6), in: Capsule())
                // Sit above the page-indicator dots when present.
                .padding(.bottom, items.count > 1 ? 44 : 24)
                .id(currentIndex)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.15), value: currentIndex)
        }
    }
}

/// One page of the zoom carousel. Owns its own scale + offset
/// state so the user can pinch this page without affecting the
/// others when they swipe back.
private struct ZoomablePage: View {
    let item: ZoomableItem

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        zoomableContent
            .scaleEffect(scale)
            .offset(offset)
            .onTapGesture(count: 2, perform: toggleZoom)
            // Pinch-to-zoom is always available.
            .gesture(zoomGesture)
            // Pan only when zoomed in. Attaching the DragGesture
            // unconditionally would steal horizontal touches from
            // the parent TabView's swipe paging — `if scale > 1`
            // hands them back when at 1×.
            .modifier(PanWhenZoomed(scale: scale, offset: $offset, lastOffset: $lastOffset))
            // Swallow any 2-finger rotation events so the image
            // never tilts — pinch in this app is zoom-only.
            .simultaneousGesture(RotateGesture().onChanged { _ in })
    }

    @ViewBuilder
    private var zoomableContent: some View {
        if let url = item.imageURL {
            CachedRemoteImage(url: url, fallbackData: item.localData)
        } else {
            localOrMissing
        }
    }

    @ViewBuilder
    private var localOrMissing: some View {
        if let localData = item.localData, let ui = UIImage(data: localData) {
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

/// View modifier that only attaches a pan `DragGesture` when the
/// host is zoomed in. Lets the parent TabView keep horizontal
/// swipes for itself at the 1× resting state.
private struct PanWhenZoomed: ViewModifier {
    let scale: CGFloat
    @Binding var offset: CGSize
    @Binding var lastOffset: CGSize

    func body(content: Content) -> some View {
        if scale > 1 {
            content.gesture(panGesture)
        } else {
            content
        }
    }

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                offset = CGSize(
                    width: lastOffset.width + value.translation.width,
                    height: lastOffset.height + value.translation.height
                )
            }
            .onEnded { _ in
                lastOffset = offset
            }
    }
}
