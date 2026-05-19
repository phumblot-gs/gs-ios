#if os(iOS)
import SwiftUI
import GSAPIClient

/// Capture flow root. Two states:
///  - `live`: ARKit camera preview, "Capture" shutter at the bottom.
///  - `captured`: frozen frame with subject masks overlaid, tap-to-
///    toggle inclusion, alert if > 1 subject. Continue / Retake CTAs.
struct MeasureCaptureView: View {
    let settings: DevSettings
    let onContinue: @MainActor (CapturedFrame, [DetectedSubject]) -> Void

    @StateObject private var controller = ARCaptureController()

    @State private var captured: CapturedFrame?
    @State private var subjects: [DetectedSubject] = []
    @State private var isDetecting = false
    @State private var detectionError: String?

    var body: some View {
        ZStack(alignment: .bottom) {
            if let captured {
                FrozenFrameEditor(
                    frame: captured,
                    subjects: $subjects,
                    isDetecting: isDetecting,
                    onRetake: { retake() },
                    onContinue: {
                        onContinue(captured, subjects.filter(\.included))
                    }
                )
                .ignoresSafeArea(edges: [.top, .leading, .trailing])
            } else {
                ARLiveView(controller: controller)
                    .ignoresSafeArea(edges: [.top, .leading, .trailing])
                shutterControls
            }
        }
        .navigationTitle("Capture")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Multiple objects detected", isPresented: Binding(
            get: { subjects.count > 1 && captured != nil && !isDetecting },
            set: { _ in }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Tap any object you don't want to measure to exclude it. Only the included objects are used for the measurement.")
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

    private var shutterControls: some View {
        VStack(spacing: 12) {
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
        }
        .padding(.bottom, 32)
    }

    private func capture() {
        guard let frame = controller.captureFrame() else { return }
        captured = frame
        subjects = []
        isDetecting = true
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
        captured = nil
        subjects = []
        detectionError = nil
    }
}

// MARK: - Frozen frame editor

private struct FrozenFrameEditor: View {
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
            Button(role: .cancel) {
                onRetake()
            } label: {
                Label("Retake", systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button {
                onContinue()
            } label: {
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
        // Bounding box is in normalized image-space with origin top-left.
        // Map it onto the area the scaled-to-fit image actually occupies
        // inside the parent ZStack (not the full frame).
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
