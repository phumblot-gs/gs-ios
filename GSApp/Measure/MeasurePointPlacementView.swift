#if os(iOS)
import SwiftUI
import SwiftData
import simd
import GSAPIClient

/// Step 3 of the capture flow. The user iterates through every
/// measurement template of the chosen category, placing the labelled
/// points one by one on the frozen capture. Each tap raycasts into the
/// depth map and produces a 3D position; the distance for a measurement
/// is the sum of segments through its points.
///
/// Placed points are drag-adjustable.
struct MeasurePointPlacementView: View {
    let settings: DevSettings
    let category: MeasureCategory
    let frame: CapturedFrame
    let onValidated: @MainActor ([String: Float]) -> Void  // name → distance (meters)

    @State private var templateIndex: Int = 0
    @State private var pointsByTemplate: [PersistentIdentifier: [PlacedPoint]] = [:]

    private var sortedTemplates: [MeasurementTemplate] {
        category.templates.sorted { $0.order < $1.order }
    }

    private var currentTemplate: MeasurementTemplate? {
        sortedTemplates.indices.contains(templateIndex) ? sortedTemplates[templateIndex] : nil
    }

    private var currentPoints: [PlacedPoint] {
        guard let id = currentTemplate?.persistentModelID else { return [] }
        return pointsByTemplate[id] ?? []
    }

    private var currentPointIndex: Int {
        currentPoints.count
    }

    private var allMeasurementsComplete: Bool {
        sortedTemplates.allSatisfy { template in
            (pointsByTemplate[template.persistentModelID]?.count ?? 0) == template.pointLabels.count
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            imageEditor
            controls
        }
        .navigationTitle(category.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Image + overlay

    private var imageEditor: some View {
        GeometryReader { geometry in
            ZStack {
                Image(uiImage: frame.image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .contentShape(Rectangle())
                    .gesture(
                        SpatialTapGesture()
                            .onEnded { event in
                                handleTap(at: event.location, in: geometry.size)
                            }
                    )

                pointOverlay(viewSize: geometry.size)
            }
        }
    }

    @ViewBuilder
    private func pointOverlay(viewSize: CGSize) -> some View {
        let renderedRect = imageRect(in: viewSize)
        // Draw segments + handles for the active template's points.
        ForEach(currentPoints.indices, id: \.self) { idx in
            if idx > 0 {
                let prev = currentPoints[idx - 1]
                let cur = currentPoints[idx]
                Path { path in
                    path.move(to: imagePointInView(prev.normalizedPoint, viewRect: renderedRect))
                    path.addLine(to: imagePointInView(cur.normalizedPoint, viewRect: renderedRect))
                }
                .stroke(.green, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }
            handle(for: idx, viewRect: renderedRect)
        }
    }

    private func handle(for index: Int, viewRect: CGRect) -> some View {
        let point = currentPoints[index]
        let screenPos = imagePointInView(point.normalizedPoint, viewRect: viewRect)
        return ZStack {
            Circle().fill(.green).frame(width: 18, height: 18)
            Circle().stroke(.white, lineWidth: 2).frame(width: 22, height: 22)
        }
        .position(screenPos)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    update(pointIndex: index, viewLocation: drag.location, viewRect: viewRect)
                }
        )
        .shadow(color: .black.opacity(0.4), radius: 2)
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let template = currentTemplate {
                if currentPointIndex < template.pointLabels.count {
                    Label("Place \(template.pointLabels[currentPointIndex])", systemImage: "scope")
                        .font(.headline)
                    Text("\(currentPointIndex + 1) / \(template.pointLabels.count) of \(template.name)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Label(
                        "\(template.name) — \(formattedDistance(of: currentPoints))",
                        systemImage: "checkmark.circle.fill"
                    )
                    .foregroundStyle(.green)
                    .font(.headline)
                }
            }
            if currentPoints.count >= 2 {
                Text("Live distance: \(formattedDistance(of: currentPoints))")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button(role: .cancel) {
                    undoLastPoint()
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .disabled(currentPoints.isEmpty)

                Spacer()

                if templateIndex < sortedTemplates.count - 1 {
                    Button {
                        templateIndex += 1
                    } label: {
                        Label("Next measurement", systemImage: "chevron.right.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isCurrentTemplateComplete)
                } else {
                    Button {
                        validate()
                    } label: {
                        Label("Validate", systemImage: "checkmark.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!allMeasurementsComplete)
                }
            }
        }
        .padding(16)
        .background(.thinMaterial)
    }

    private var isCurrentTemplateComplete: Bool {
        guard let template = currentTemplate else { return false }
        return currentPoints.count >= template.pointLabels.count
    }

    // MARK: - Tap handling

    private func handleTap(at viewLocation: CGPoint, in viewSize: CGSize) {
        guard let template = currentTemplate else { return }
        guard currentPoints.count < template.pointLabels.count else { return }
        let rect = imageRect(in: viewSize)
        guard rect.contains(viewLocation) else { return }
        let normalized = normalizedPoint(from: viewLocation, viewRect: rect)
        guard let world = projectToWorld(normalized: normalized) else { return }
        let new = PlacedPoint(normalizedPoint: normalized, world: world)
        pointsByTemplate[template.persistentModelID, default: []].append(new)
    }

    private func update(pointIndex: Int, viewLocation: CGPoint, viewRect: CGRect) {
        guard let template = currentTemplate else { return }
        let clamped = CGPoint(
            x: viewLocation.x.clamped(to: viewRect.minX...viewRect.maxX),
            y: viewLocation.y.clamped(to: viewRect.minY...viewRect.maxY)
        )
        let normalized = normalizedPoint(from: clamped, viewRect: viewRect)
        guard let world = projectToWorld(normalized: normalized) else { return }
        var list = pointsByTemplate[template.persistentModelID] ?? []
        guard list.indices.contains(pointIndex) else { return }
        list[pointIndex] = PlacedPoint(normalizedPoint: normalized, world: world)
        pointsByTemplate[template.persistentModelID] = list
    }

    private func undoLastPoint() {
        guard let template = currentTemplate else { return }
        var list = pointsByTemplate[template.persistentModelID] ?? []
        _ = list.popLast()
        pointsByTemplate[template.persistentModelID] = list
    }

    private func projectToWorld(normalized: CGPoint) -> SIMD3<Float>? {
        guard let depth = frame.depthMap else { return nil }
        return DepthRaycaster.project(
            normalizedPoint: normalized,
            depthMap: depth,
            intrinsics: frame.cameraIntrinsics,
            imageSize: frame.image.size
        )
    }

    // MARK: - Geometry helpers

    /// Compute the rect the image occupies inside `viewSize` under
    /// `scaledToFit`. We need this to convert tap locations back to
    /// image-relative normalized coordinates.
    private func imageRect(in viewSize: CGSize) -> CGRect {
        let imageAspect = frame.image.size.width / frame.image.size.height
        let viewAspect = viewSize.width / viewSize.height
        let renderedSize: CGSize
        if imageAspect > viewAspect {
            renderedSize = CGSize(width: viewSize.width, height: viewSize.width / imageAspect)
        } else {
            renderedSize = CGSize(width: viewSize.height * imageAspect, height: viewSize.height)
        }
        let origin = CGPoint(
            x: (viewSize.width - renderedSize.width) / 2,
            y: (viewSize.height - renderedSize.height) / 2
        )
        return CGRect(origin: origin, size: renderedSize)
    }

    private func normalizedPoint(from viewPoint: CGPoint, viewRect: CGRect) -> CGPoint {
        let x = (viewPoint.x - viewRect.minX) / viewRect.width
        let y = (viewPoint.y - viewRect.minY) / viewRect.height
        return CGPoint(x: x, y: y)
    }

    private func imagePointInView(_ normalized: CGPoint, viewRect: CGRect) -> CGPoint {
        CGPoint(
            x: viewRect.minX + normalized.x * viewRect.width,
            y: viewRect.minY + normalized.y * viewRect.height
        )
    }

    // MARK: - Distance display

    private func formattedDistance(of points: [PlacedPoint]) -> String {
        let meters = DepthRaycaster.chainDistance(points.map(\.world))
        let value = settings.measurementUnit.convert(meters: Double(meters))
        return String(format: "%.1f %@", value, settings.measurementUnit.apiSymbol)
    }

    // MARK: - Validation

    private func validate() {
        var result: [String: Float] = [:]
        for template in sortedTemplates {
            let points = pointsByTemplate[template.persistentModelID] ?? []
            guard points.count == template.pointLabels.count else { continue }
            let meters = DepthRaycaster.chainDistance(points.map(\.world))
            result[template.name] = meters
        }
        onValidated(result)
    }
}

/// One placed point: where the user tapped on the (scaled-to-fit) image,
/// and the 3D world position the depth raycaster projected for it.
struct PlacedPoint: Equatable, Sendable {
    let normalizedPoint: CGPoint  // 0...1 in image-space
    let world: SIMD3<Float>       // meters, camera coordinate space
}
#endif
