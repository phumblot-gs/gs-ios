#if os(iOS)
import SwiftUI
import simd
import GSScanner
import GSAPIClient
import GSCore

/// Final step of the measure flow. Shows the détouré reference photo
/// (kept subjects on white) with each captured measurement drawn as a
/// segment between two reprojected endpoints, plus a list of values.
/// "Attach to a reference" scans / picks a Grand Shooting reference and
/// posts the values via `PUT /reference/:id/extra`.
struct MeasureSummaryView: View {
    let settings: DevSettings
    @Bindable var category: MeasureCategory
    let referenceFrame: CapturedFrame
    let includedSubjects: [DetectedSubject]
    let captures: [MeasurementCapture]
    /// When set, the save step is bound to this reference: a single
    /// "Save" button on the form, no scanner sheet. The detail screen
    /// that opened this flow already knows which reference we're on.
    let attachedTo: Reference?
    let onDone: @MainActor () -> Void

    @State private var cutoutImage: UIImage?
    @State private var resolveSheetVisible = false
    @State private var saving = false
    @State private var saveError: String?
    @State private var savedReferenceRef: String?

    var body: some View {
        Form {
            previewSection
            gsLinkSection
            measurementsSection
            saveSection
            if let savedReferenceRef {
                Section {
                    Label("Saved to \(savedReferenceRef)", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Button("Done") { onDone() }
                }
            }
            if let saveError {
                Section {
                    Label(saveError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }
        }
        .navigationTitle("Validate")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if cutoutImage == nil {
                cutoutImage = MeasureSubjectCutout.make(
                    frame: referenceFrame,
                    includedSubjects: includedSubjects
                )
            }
        }
        .sheet(isPresented: $resolveSheetVisible) {
            NavigationStack {
                ReferenceScanForMeasures(settings: settings) { ref in
                    resolveSheetVisible = false
                    Task { await save(toReference: ref) }
                }
            }
        }
    }

    // MARK: - Sections

    private var previewSection: some View {
        Section {
            ZStack {
                Image(uiImage: cutoutImage ?? referenceFrame.image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 320)

                GeometryReader { geometry in
                    let rect = renderedRect(in: geometry.size, imageSize: referenceFrame.image.size)
                    SegmentsOverlay(
                        captures: captures,
                        frame: referenceFrame,
                        viewRect: rect
                    )
                }
            }
        } header: {
            Text("Reference photo")
        } footer: {
            Text("Segments are reprojected onto the original photo from the LiDAR world coordinates captured during placement.")
        }
    }

    private var gsLinkSection: some View {
        Section {
            GSCategoryLinkRow(selection: $category.gsCategoryID)
        } header: {
            Text("Grand Shooting link")
        } footer: {
            Text("Pick the Grand Shooting catalog category these measurements belong to. The link is saved on the local category for future captures.")
        }
    }

    private var measurementsSection: some View {
        Section {
            HStack {
                Image(systemName: "tag.fill").foregroundStyle(.tint)
                Text(category.name).font(.headline)
            }
            ForEach(orderedRows) { row in
                HStack {
                    Text(row.name)
                    Spacer()
                    Text(format(meters: row.meters))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Measurements")
        }
    }

    @ViewBuilder
    private var saveSection: some View {
        if savedReferenceRef == nil {
            if let attachedTo {
                Section {
                    Button {
                        Task { await save(toReference: attachedTo) }
                    } label: {
                        if saving {
                            HStack { ProgressView(); Text("Saving…") }
                        } else {
                            Label("Save measurements", systemImage: "checkmark.seal.fill")
                        }
                    }
                    .disabled(saving)
                } header: {
                    Text("Reference")
                } footer: {
                    Text("Will save these measurements as `extra.measures` on \(attachedTo.ref).")
                }
            } else {
                Section {
                    Button {
                        resolveSheetVisible = true
                    } label: {
                        if saving {
                            HStack { ProgressView(); Text("Saving…") }
                        } else {
                            Label("Attach to a reference", systemImage: "link.badge.plus")
                        }
                    }
                    .disabled(saving)
                } footer: {
                    Text("Scan or pick a reference to save these measurements as `extra.measures` on Grand Shooting.")
                }
            }
        }
    }

    // MARK: - Data

    private var orderedRows: [Row] {
        captures
            .sorted(by: { $0.order < $1.order })
            .map { Row(id: $0.id, name: $0.templateName, meters: $0.meters) }
    }

    private struct Row: Identifiable {
        let id: UUID
        let name: String
        let meters: Float
    }

    private func format(meters: Float) -> String {
        let value = settings.measurementUnit.convert(meters: Double(meters))
        return String(format: "%.1f %@", value, settings.measurementUnit.apiSymbol)
    }

    /// Compute the rect a `scaledToFit` image occupies inside `viewSize`,
    /// matching the SegmentsOverlay's drawing rect.
    private func renderedRect(in viewSize: CGSize, imageSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGRect(origin: .zero, size: viewSize)
        }
        let imageAspect = imageSize.width / imageSize.height
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

    // MARK: - Save

    @MainActor
    private func save(toReference reference: Reference) async {
        guard let referenceID = reference.id else {
            saveError = "Reference is missing a reference_id."
            return
        }
        saving = true
        saveError = nil
        defer { saving = false }

        var payload: [String: ReferenceExtraService.MeasureValue] = [:]
        let unit = settings.measurementUnit
        for capture in captures where capture.isComplete {
            let value = unit.convert(meters: Double(capture.meters))
            let rounded = (value * 10).rounded() / 10
            payload[capture.templateName] = .init(value: rounded, unit: unit.apiSymbol)
        }

        let service = ReferenceExtraService(environment: settings.currentEnvironment)
        do {
            try await service.updateMeasures(referenceID: referenceID, measures: payload)
            savedReferenceRef = reference.ref
        } catch let err as GSHTTPClient.HTTPError {
            saveError = err.userMessage
        } catch {
            saveError = error.localizedDescription
        }
    }
}

// MARK: - Segments overlay

/// Draws every captured measurement as a green segment with circle
/// endpoints and a numeric label centered on the segment.
private struct SegmentsOverlay: View {
    let captures: [MeasurementCapture]
    let frame: CapturedFrame
    let viewRect: CGRect

    var body: some View {
        ZStack {
            ForEach(captures) { capture in
                if capture.worldPoints.count >= 2 {
                    SegmentView(
                        worldPoints: capture.worldPoints,
                        frame: frame,
                        viewRect: viewRect
                    )
                }
            }
        }
    }
}

private struct SegmentView: View {
    let worldPoints: [SIMD3<Float>]
    let frame: CapturedFrame
    let viewRect: CGRect

    var body: some View {
        if let projected = projectAll() {
            ZStack {
                Path { path in
                    path.move(to: projected[0])
                    for p in projected.dropFirst() { path.addLine(to: p) }
                }
                .stroke(.green, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))

                ForEach(projected.indices, id: \.self) { idx in
                    Circle()
                        .fill(.green)
                        .frame(width: 10, height: 10)
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                        .position(projected[idx])
                }
            }
        }
    }

    private func projectAll() -> [CGPoint]? {
        var pts: [CGPoint] = []
        for world in worldPoints {
            guard let n = MeasureReprojection.projectToNormalized(worldPoint: world, frame: frame) else {
                return nil
            }
            pts.append(CGPoint(
                x: viewRect.minX + n.x * viewRect.width,
                y: viewRect.minY + n.y * viewRect.height
            ))
        }
        return pts
    }
}

// MARK: - Reference selection (embedded scanner + manual entry)

private struct ReferenceScanForMeasures: View {
    let settings: DevSettings
    let onResolved: @MainActor (Reference) -> Void

    @State private var manualValue = ""
    @State private var isLookingUp = false
    @State private var error: String?
    @State private var feedback = ScannerFeedback()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .bottom) {
            LiveBarcodeScannerView(resetDelaySeconds: 0.5) { code in
                Task { await resolve(value: code.payload) }
            }
            .ignoresSafeArea()

            VStack(spacing: 10) {
                if isLookingUp {
                    HStack { ProgressView().tint(.white); Text("Looking up…").foregroundStyle(.white) }
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.black.opacity(0.6), in: Capsule())
                }
                if let error {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(8)
                        .background(.thinMaterial, in: Capsule())
                }
                HStack {
                    TextField("Or enter ref / EAN manually", text: $manualValue)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button("Look up") {
                        Task { await resolve(value: manualValue) }
                    }
                    .disabled(manualValue.trimmingCharacters(in: .whitespaces).isEmpty || isLookingUp)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
        .navigationTitle("Attach to reference")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Cancel") { dismiss() }
            }
        }
    }

    @MainActor
    private func resolve(value: String) async {
        guard !isLookingUp else { return }
        isLookingUp = true
        error = nil
        defer { isLookingUp = false }
        feedback.didDetectCode()

        let service = ReferenceLookupService(environment: settings.currentEnvironment)
        do {
            let refs = try await service.lookup(scannedValue: value, by: settings.searchAttribute)
            if let first = refs.first {
                feedback.didFindReference()
                onResolved(first)
            } else {
                feedback.didFailLookup(reason: .notFound)
                error = "No reference for \(value)."
            }
        } catch let err as GSHTTPClient.HTTPError {
            feedback.didFailLookup(reason: .transport)
            error = err.userMessage
        } catch let other {
            feedback.didFailLookup(reason: .other)
            error = other.localizedDescription
        }
    }
}
#endif
