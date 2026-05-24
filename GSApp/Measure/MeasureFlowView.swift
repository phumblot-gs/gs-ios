#if os(iOS)
import SwiftUI
import SwiftData
import GSAPIClient

/// Container view orchestrating the whole measure flow on a single
/// SwiftUI screen. Holds one persistent ARKit session through every
/// step so world coordinates captured during point placement stay
/// registered with the reference photo's `cameraTransform`.
///
/// Two flow modes depending on `attachedTo`:
///
/// **Creation flow** (attachedTo == nil — launched from the Measures
/// tab "+"):
///   1. `.capturing` → 2. `.editing` → 3. `.naming` →
///   4. `.placing` (variable points) → save the new category.
///
/// **Reference-bound flow** (attachedTo != nil — launched from a
/// reference detail page):
///   1. `.capturing` → 2. `.editing` →
///   3. auto-match the GS category to a local one, otherwise
///      `.picking` (search-only) → 4. `.placing` (fixed point
///      counts from the chosen category) → 5. `.summary` (attach to
///      the reference).
struct MeasureFlowView: View {
    let settings: DevSettings
    let attachedTo: Reference?
    let onDone: @MainActor () -> Void

    @Environment(\.modelContext) private var modelContext
    @StateObject private var coordinator = MeasureFlowCoordinator()
    @State private var step: Step = .capturing

    @State private var capturedFrame: CapturedFrame?
    @State private var subjects: [DetectedSubject] = []
    @State private var category: MeasureCategory?
    @State private var categoryDraft: CategoryDraft?
    @State private var captures: [MeasurementCapture] = []

    @State private var isDetecting = false
    @State private var detectionError: String?

    enum Step: Equatable {
        case capturing
        case editing
        case naming    // creation flow only
        case picking   // reference-bound flow only
        case placing
        case summary   // reference-bound flow only
    }

    private var showsLive: Bool {
        step == .capturing || step == .placing
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ARLiveView(coordinator: coordinator)
                .ignoresSafeArea()
                .opacity(showsLive ? 1 : 0)

            stepContent
        }
        .alert("Couldn't detect any object", isPresented: Binding(
            get: { detectionError != nil },
            set: { if !$0 { detectionError = nil } }
        )) {
            Button("Retake", role: .cancel) { retake() }
        } message: {
            Text(detectionError ?? "")
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .capturing: capturingOverlay
        case .editing:   editingOverlay
        case .naming:    namingOverlay
        case .picking:   pickingOverlay
        case .placing:   placingOverlay
        case .summary:   summaryOverlay
        }
    }

    // MARK: - Step 1: Capturing

    private var capturingOverlay: some View {
        VStack(spacing: 12) {
            HStack {
                Button {
                    onDone()
                } label: {
                    Image(systemName: "xmark")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(.black.opacity(0.5), in: Circle())
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            Spacer()

            Text("Lay the product flat on a clean surface and frame it in the camera.")
                .font(.footnote)
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.black.opacity(0.6), in: Capsule())

            Button {
                capture()
            } label: {
                ZStack {
                    Circle().fill(.white).frame(width: 76, height: 76)
                    Circle().stroke(.white, lineWidth: 4).frame(width: 88, height: 88)
                }
            }
            .accessibilityLabel("Capture frame")
            .padding(.bottom, 32)
        }
    }

    // MARK: - Step 2: Editing subjects

    private var editingOverlay: some View {
        Group {
            if let capturedFrame {
                ZStack(alignment: .bottom) {
                    FrozenFrameEditor(
                        frame: capturedFrame,
                        subjects: $subjects,
                        isDetecting: isDetecting,
                        onRetake: { retake() },
                        onContinue: {
                            subjects = subjects.filter(\.included)
                            advancePastEditing()
                        }
                    )
                    .ignoresSafeArea()
                }
                .background(Color.black.ignoresSafeArea())
            }
        }
    }

    // MARK: - Step 3a: Naming (creation flow only)

    @ViewBuilder
    private var namingOverlay: some View {
        if let capturedFrame {
            NavigationStack {
                MeasureCategoryNamingView(
                    capturedFrame: capturedFrame,
                    onContinue: { draft in
                        categoryDraft = draft
                        startPlacementForDraft(draft)
                    },
                    onCancel: { onDone() }
                )
            }
            .background(Color(.systemBackground).ignoresSafeArea())
        }
    }

    // MARK: - Step 3b: Picking (reference-bound flow only)

    @ViewBuilder
    private var pickingOverlay: some View {
        if capturedFrame != nil {
            NavigationStack {
                MeasureCategorySearchPickerView(
                    onSelected: { pickedCategory in
                        category = pickedCategory
                        startPlacement(for: pickedCategory)
                    },
                    onCancel: { onDone() }
                )
            }
            .background(Color(.systemBackground).ignoresSafeArea())
        }
    }

    // MARK: - Step 4: Placing points

    private var placingOverlay: some View {
        Group {
            if let capturedFrame {
                let title = category?.name ?? categoryDraft?.name ?? ""
                let isCreating = categoryDraft != nil
                MeasureFlowPlacingOverlay(
                    settings: settings,
                    coordinator: coordinator,
                    categoryName: title,
                    referenceFrame: capturedFrame,
                    includedSubjects: subjects,
                    captures: $captures,
                    finalizeButtonTitle: isCreating ? "Save" : "Validate",
                    finalizeButtonIcon: isCreating ? "square.and.arrow.down.fill" : "checkmark.circle.fill",
                    // X dismisses the whole flow back to whoever
                    // launched it (reference detail or measures tab).
                    onCancel: { onDone() },
                    onFinalize: {
                        if isCreating {
                            saveNewCategory()
                        } else {
                            step = .summary
                        }
                    }
                )
            }
        }
    }

    // MARK: - Step 5: Summary

    private var summaryOverlay: some View {
        Group {
            if let category, let capturedFrame {
                NavigationStack {
                    MeasureSummaryView(
                        settings: settings,
                        category: category,
                        referenceFrame: capturedFrame,
                        includedSubjects: subjects,
                        captures: captures,
                        attachedTo: attachedTo,
                        onDone: { onDone() }
                    )
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Back") { step = .placing }
                        }
                    }
                }
                .background(Color(.systemBackground).ignoresSafeArea())
            }
        }
    }

    // MARK: - Actions

    private func capture() {
        guard let frame = coordinator.captureFrame() else { return }
        capturedFrame = frame
        subjects = []
        isDetecting = true
        step = .editing
        Task {
            do {
                let detected = try await SubjectMaskService.detect(in: frame.image)
                await MainActor.run {
                    subjects = detected
                    isDetecting = false
                    if detected.isEmpty {
                        detectionError = "No object was found in the frame. Move closer or check the lighting."
                    }
                }
            } catch {
                await MainActor.run {
                    isDetecting = false
                    detectionError = error.localizedDescription
                }
            }
        }
    }

    private func retake() {
        coordinator.stopReticle()
        capturedFrame = nil
        subjects = []
        category = nil
        categoryDraft = nil
        captures = []
        detectionError = nil
        step = .capturing
    }

    /// Reference-bound only — uses an EXISTING category's templates
    /// (including their `pointCount`) to seed the captures.
    private func startPlacement(for category: MeasureCategory) {
        captures = category.templates
            .sorted(by: { $0.order < $1.order })
            .map { MeasurementCapture(templateName: $0.name, order: $0.order, worldPoints: []) }
        step = .placing
    }

    /// Creation flow — seeds the captures from the user-entered
    /// measurement names. `pointCount` for each template is unknown
    /// at this point; it'll be set on save from the worldPoints count.
    private func startPlacementForDraft(_ draft: CategoryDraft) {
        captures = draft.measurementNames.enumerated().map { idx, name in
            MeasurementCapture(templateName: name, order: idx, worldPoints: [])
        }
        category = nil
        step = .placing
    }

    /// After the editing step, route based on whether we're in
    /// creation or reference-bound mode. Creation goes to `.naming`
    /// to collect category + measurement names. Reference-bound
    /// tries to auto-match an existing local category from the
    /// reference's GS category_id; failing that, falls back to a
    /// search-only picker over existing local categories.
    private func advancePastEditing() {
        if attachedTo == nil {
            step = .naming
            return
        }
        if let auto = autoMatchedCategory() {
            category = auto
            startPlacement(for: auto)
        } else {
            step = .picking
        }
    }

    private func autoMatchedCategory() -> MeasureCategory? {
        guard let reference = attachedTo, let gsCategoryID = reference.categoryID else { return nil }
        let descriptor = FetchDescriptor<MeasureCategory>(
            predicate: #Predicate { $0.gsCategoryID == gsCategoryID }
        )
        guard let matches = try? modelContext.fetch(descriptor) else { return nil }
        // If several locals link to the same GS category, take the
        // most recently created — newer schemas typically reflect the
        // latest measurement requirements.
        return matches.sorted(by: { $0.createdAt > $1.createdAt }).first
    }

    /// Save the new category at the end of the creation flow. Builds
    /// the illustration image (subject cutout + segments) and saves
    /// it as the category's `exampleImageData`, plus the
    /// `MeasurementTemplate`s with their pointCount from what the
    /// user actually placed.
    private func saveNewCategory() {
        guard let draft = categoryDraft, let capturedFrame else { return }
        let cutout = MeasureSubjectCutout.make(frame: capturedFrame, includedSubjects: subjects)
        let illustration = MeasureIllustration.render(
            cutout: cutout,
            frame: capturedFrame,
            captures: captures,
            unit: settings.measurementUnit
        )
        let illustrationData = illustration.jpegData(compressionQuality: 0.8)
        let newCategory = MeasureCategory(
            name: draft.name,
            code: draft.code,
            gsCategoryID: draft.gsCategoryID,
            imageEmbedding: nil,
            exampleImageData: illustrationData
        )
        modelContext.insert(newCategory)
        for (idx, capture) in captures.enumerated() {
            let template = MeasurementTemplate(
                name: capture.templateName,
                order: idx,
                pointCount: capture.worldPoints.count
            )
            template.category = newCategory
            modelContext.insert(template)
        }
        do {
            try modelContext.save()
        } catch {
            print("[MeasureFlowView] save failed: \(error)")
        }
        onDone()
    }
}

// MARK: - Frozen frame editor (shared with capture step)

struct FrozenFrameEditor: View {
    let frame: CapturedFrame
    @Binding var subjects: [DetectedSubject]
    let isDetecting: Bool
    let onRetake: () -> Void
    let onContinue: () -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            GeometryReader { geometry in
                ZStack {
                    Image(uiImage: frame.image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geometry.size.width, height: geometry.size.height)

                    ForEach(subjects) { subject in
                        SubjectMaskOverlay(
                            subject: subject,
                            frameSize: geometry.size,
                            imageSize: frame.image.size
                        )
                        .onTapGesture {
                            toggle(subject: subject)
                        }
                    }
                }
            }
            controls
        }
    }

    private func toggle(subject: DetectedSubject) {
        if let index = subjects.firstIndex(where: { $0.id == subject.id }) {
            subjects[index].included.toggle()
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button(role: .cancel) { onRetake() } label: {
                Label("Retake", systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button { onContinue() } label: {
                if isDetecting {
                    HStack { ProgressView().tint(.white); Text("Detecting…") }
                        .frame(maxWidth: .infinity)
                } else {
                    Label("Continue", systemImage: "arrow.right")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isDetecting || subjects.filter(\.included).isEmpty)
        }
        .controlSize(.large)
        .padding(16)
        .background(.thinMaterial)
    }
}

private struct SubjectMaskOverlay: View {
    let subject: DetectedSubject
    let frameSize: CGSize
    let imageSize: CGSize

    var body: some View {
        let rect = renderedRect(in: frameSize, imageSize: imageSize)
        Rectangle()
            .strokeBorder(subject.included ? Color.green : Color.red, lineWidth: 3)
            .background(
                (subject.included ? Color.green : Color.red).opacity(0.18)
            )
            .frame(
                width: subject.boundingBox.width * rect.width,
                height: subject.boundingBox.height * rect.height
            )
            .position(
                x: rect.minX + subject.boundingBox.midX * rect.width,
                y: rect.minY + subject.boundingBox.midY * rect.height
            )
    }

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
}
#endif
