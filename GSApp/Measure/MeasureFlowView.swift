#if os(iOS)
import SwiftUI
import SwiftData
import GSAPIClient

/// Container view orchestrating the whole measure flow on a single
/// SwiftUI screen. Holds one persistent ARKit session through every
/// step so world coordinates captured during point placement stay
/// registered with the reference photo's `cameraTransform`.
///
/// Steps:
///   1. `.capturing` — live AR preview + shutter.
///   2. `.editing`   — frozen photo with subject masks; user picks
///                     which object(s) to keep.
///   3. `.picking`   — choose / create the local category.
///   4. `.placing`   — live AR with reticle; user aims the device at
///                     each point and the stability tracker locks
///                     them automatically.
///   5. `.summary`   — cutout photo + reprojected segments + save.
struct MeasureFlowView: View {
    let settings: DevSettings
    /// Optional bound reference. When set, the flow auto-attaches the
    /// captured measurements to this reference at validation (no
    /// scanner sheet), and tries to pre-select the local category by
    /// matching `reference.categoryID` against
    /// `MeasureCategory.gsCategoryID`.
    let attachedTo: Reference?
    let onDone: @MainActor () -> Void

    @Environment(\.modelContext) private var modelContext
    @StateObject private var coordinator = MeasureFlowCoordinator()
    @State private var step: Step = .capturing

    @State private var capturedFrame: CapturedFrame?
    @State private var subjects: [DetectedSubject] = []
    @State private var category: MeasureCategory?
    @State private var captures: [MeasurementCapture] = []

    @State private var isDetecting = false
    @State private var detectionError: String?

    enum Step: Equatable {
        case capturing
        case editing
        case picking
        case placing
        case summary
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

    // MARK: - Step 3: Picking category

    @ViewBuilder
    private var pickingOverlay: some View {
        if let capturedFrame {
            if attachedTo != nil {
                NavigationStack {
                    MeasureCategorySearchPickerView(
                        onSelected: { pickedCategory in
                            category = pickedCategory
                            startPlacement(for: pickedCategory)
                        },
                        onCancel: { retake() }
                    )
                }
                .background(Color(.systemBackground).ignoresSafeArea())
            } else {
                NavigationStack {
                    MeasureCategoryPickerView(
                        settings: settings,
                        frame: capturedFrame,
                        includedSubjects: subjects
                    ) { pickedCategory, _ in
                        category = pickedCategory
                        startPlacement(for: pickedCategory)
                    }
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Retake") { retake() }
                        }
                    }
                }
                .background(Color(.systemBackground).ignoresSafeArea())
            }
        }
    }

    // MARK: - Step 4: Placing points

    private var placingOverlay: some View {
        Group {
            if let category, let capturedFrame {
                MeasureFlowPlacingOverlay(
                    settings: settings,
                    coordinator: coordinator,
                    category: category,
                    referenceFrame: capturedFrame,
                    includedSubjects: subjects,
                    captures: $captures,
                    // X dismisses the whole flow back to whoever
                    // launched it (reference detail or measures tab).
                    // Not the picker step — landing on a category
                    // list the user wasn't navigating to is confusing.
                    onCancel: { onDone() },
                    onValidated: { step = .summary }
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
        captures = []
        detectionError = nil
        step = .capturing
    }

    private func startPlacement(for category: MeasureCategory) {
        captures = category.templates
            .sorted(by: { $0.order < $1.order })
            .map { MeasurementCapture(templateName: $0.name, order: $0.order, worldPoints: []) }
        step = .placing
    }

    /// After the editing step, decide whether to surface the category
    /// picker or go straight to placement. Reference-bound mode skips
    /// the picker when the reference's GS category resolves to exactly
    /// one local MeasureCategory.
    private func advancePastEditing() {
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
