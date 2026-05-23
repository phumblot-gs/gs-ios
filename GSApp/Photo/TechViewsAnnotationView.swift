import SwiftUI
import UIKit
import GSCamera

/// Bottom-sheet style annotation surface shown after a photo is
/// taken. In `.ocr` capture mode each OCR observation and each
/// pictogram candidate is rendered as a tappable summary row:
/// tapping opens a dedicated editor sheet that holds the user's
/// full attention — text + category + delete for OCR via
/// `OCRObservationEditor`, label + learning for pictograms via
/// `PictoLabelPicker`. Both sheets share `TechViewEditorShell`, so
/// the UX rhythm (Cancel, keyboard dismiss, presentation detents)
/// is identical. In `.presentation` / `.detail` modes the view
/// only offers preview + Retake/Save — there's nothing to
/// annotate, the user just confirms the shot.
struct TechViewsAnnotationView: View {
    let image: UIImage
    let captureMode: CaptureMode
    let observations: [OCRObservation]
    let isRunningOCR: Bool
    let candidates: [TechViewsPictoDetection.Candidate]
    let isDetectingPictos: Bool
    @Binding var assignments: [UUID: TechViewCategory]
    @Binding var ocrEdits: [UUID: String]
    @Binding var hiddenOCRIDs: Set<UUID>
    @Binding var pictoAnnotations: [UUID: PictoAnnotation]
    let onRetake: () -> Void
    let onSave: () -> Void

    @State private var pickerTarget: PickerTarget?
    @State private var ocrEditTarget: OCREditTarget?

    private struct PickerTarget: Identifiable {
        let id: UUID
    }

    private struct OCREditTarget: Identifiable {
        let id: UUID
        let observation: OCRObservation
    }

    private var visibleObservations: [OCRObservation] {
        observations.filter { !hiddenOCRIDs.contains($0.id) }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                if captureMode == .ocr {
                    preview
                    annotationsScroll
                } else {
                    largePreview
                }
                footer
            }
        }
        .sheet(item: $pickerTarget) { target in
            PictoLabelPicker(
                annotation: annotationBinding(for: target.id),
                onDismiss: { pickerTarget = nil }
            )
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $ocrEditTarget) { target in
            OCRObservationEditor(
                observation: target.observation,
                sourceImage: image,
                ocrEdits: $ocrEdits,
                assignments: $assignments,
                hiddenOCRIDs: $hiddenOCRIDs,
                onDismiss: { ocrEditTarget = nil }
            )
        }
    }

    private var preview: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: 200)
            .padding(.top, 8)
    }

    /// Edge-to-edge preview used by the photo / detail modes —
    /// nothing to annotate, so the shot fills the available space
    /// above the footer.
    private var largePreview: some View {
        VStack(spacing: 0) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 12)
        }
        .background(Color.black)
    }

    private var annotationsScroll: some View {
        ScrollView {
            VStack(spacing: 14) {
                ocrSection
                pictoSection
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
        }
        .background(.thinMaterial)
    }

    // MARK: - OCR section

    @ViewBuilder
    private var ocrSection: some View {
        sectionHeader(
            title: "Detected text",
            isLoading: isRunningOCR,
            loadingMessage: "Reading…"
        )

        if visibleObservations.isEmpty && !isRunningOCR {
            emptyState(observations.isEmpty
                       ? "No text detected on this shot."
                       : "All detected text was removed.")
        } else {
            LazyVStack(spacing: 8) {
                ForEach(visibleObservations) { obs in
                    observationRow(obs)
                }
            }
        }
    }

    private func observationRow(_ obs: OCRObservation) -> some View {
        let text = ocrEdits[obs.id] ?? obs.text
        let category = assignments[obs.id]
        return Button {
            ocrEditTarget = OCREditTarget(id: obs.id, observation: obs)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(text)
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                    HStack(spacing: 8) {
                        Text("\(Int(obs.confidence * 100))%")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        if let category {
                            Label(category.displayName, systemImage: category.symbolName)
                                .labelStyle(.titleAndIcon)
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.accentColor.opacity(0.25), in: Capsule())
                                .foregroundStyle(.white)
                        } else {
                            Text("Tap to categorise")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Picto section

    @ViewBuilder
    private var pictoSection: some View {
        sectionHeader(
            title: "Pictograms",
            isLoading: isDetectingPictos,
            loadingMessage: "Scanning…"
        )

        if candidates.isEmpty && !isDetectingPictos {
            emptyState("No pictograms detected on this shot.")
        } else {
            LazyVStack(spacing: 8) {
                ForEach(candidates) { candidate in
                    pictoRow(candidate)
                }
            }
        }
    }

    private func pictoRow(_ candidate: TechViewsPictoDetection.Candidate) -> some View {
        let annotation = pictoAnnotations[candidate.id]
        let hasLabel = annotation?.hasUsableContent ?? false
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(uiImage: candidate.crop)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 60, height: 60)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                Button {
                    pickerTarget = PickerTarget(id: candidate.id)
                } label: {
                    pictoLabelContent(annotation: annotation)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
            }
            if hasLabel {
                labelledControls(candidate: candidate)
            }
        }
        .padding(12)
        .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private func pictoLabelContent(annotation: PictoAnnotation?) -> some View {
        if let annotation, !annotation.label.isEmpty {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(annotation.label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    if let distance = annotation.suggestionDistance,
                       annotation.matchedLearnedID != nil {
                        Text(String(format: "Suggested · distance %.1f", distance))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else if annotation.matchedLearnedID == nil {
                        Text("New label")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(spacing: 8) {
                Text("Choose label")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(Color.accentColor.opacity(0.25), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func labelledControls(candidate: TechViewsPictoDetection.Candidate) -> some View {
        let categoryBinding = Binding<TechViewCategory?>(
            get: { pictoAnnotations[candidate.id]?.category },
            set: { newValue in
                guard var current = pictoAnnotations[candidate.id] else { return }
                current.category = newValue
                pictoAnnotations[candidate.id] = current
            }
        )
        return HStack(spacing: 10) {
            TechViewCategoryControl(selection: categoryBinding)
                .frame(maxWidth: .infinity, alignment: .leading)
            TechViewDeleteButton {
                pictoAnnotations.removeValue(forKey: candidate.id)
            }
        }
    }

    // MARK: - Shared

    private func annotationBinding(for id: UUID) -> Binding<PictoAnnotation> {
        Binding(
            get: { pictoAnnotations[id] ?? PictoAnnotation(id: id, label: "", category: nil) },
            set: { newValue in
                if newValue.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    pictoAnnotations.removeValue(forKey: id)
                } else {
                    pictoAnnotations[id] = newValue
                }
            }
        )
    }

    private func sectionHeader(title: String, isLoading: Bool, loadingMessage: String) -> some View {
        HStack {
            Text(title)
                .font(.subheadline.weight(.medium))
            Spacer()
            if isLoading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(loadingMessage).font(.caption)
                }
            }
        }
        .foregroundStyle(.white)
    }

    private func emptyState(_ message: String) -> some View {
        Text(message)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button(role: .cancel) { onRetake() } label: {
                Label("Retake", systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.white)

            Button { onSave() } label: {
                Label("Save", systemImage: "checkmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .controlSize(.large)
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .background(.thinMaterial)
    }
}
