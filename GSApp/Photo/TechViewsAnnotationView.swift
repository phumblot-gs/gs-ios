import SwiftUI
import UIKit

/// Bottom-sheet style annotation surface shown after a photo is
/// taken. Each OCR observation gets an inline, full-width editable
/// TextField (corrections are kept until save) plus a category
/// picker and a Delete button that removes the row outright. Picto
/// candidates follow the same two-state UX: tap the label area to
/// open `PictoLabelPicker`, then the labelled row exposes a
/// category picker and Delete button. A keyboard accessory bar
/// adds a "Done" button so the user can dismiss the keyboard if a
/// field was tapped by accident.
struct TechViewsAnnotationView: View {
    let image: UIImage
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
    @FocusState private var focusedOCR: UUID?

    private struct PickerTarget: Identifiable {
        let id: UUID
    }

    private var visibleObservations: [OCRObservation] {
        observations.filter { !hiddenOCRIDs.contains($0.id) }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                preview
                annotationsScroll
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
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button {
                    focusedOCR = nil
                } label: {
                    Label("Hide keyboard", systemImage: "keyboard.chevron.compact.down")
                        .labelStyle(.titleAndIcon)
                        .font(.body.weight(.medium))
                }
            }
        }
    }

    private var preview: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: 200)
            .padding(.top, 8)
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
        let textBinding = Binding<String>(
            get: { ocrEdits[obs.id] ?? obs.text },
            set: { ocrEdits[obs.id] = $0 }
        )
        let categoryBinding = Binding<TechViewCategory?>(
            get: { assignments[obs.id] },
            set: { newValue in
                if let newValue {
                    assignments[obs.id] = newValue
                } else {
                    assignments.removeValue(forKey: obs.id)
                }
            }
        )
        return VStack(alignment: .leading, spacing: 10) {
            TextField("Text", text: textBinding, axis: .vertical)
                .focused($focusedOCR, equals: obs.id)
                .font(.subheadline)
                .foregroundStyle(.white)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .lineLimit(1...5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            HStack(spacing: 10) {
                Text("\(Int(obs.confidence * 100))%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                categoryMenu(selection: categoryBinding)
                deleteButton {
                    deleteObservation(obs.id)
                }
            }
        }
        .padding(12)
        .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func deleteObservation(_ id: UUID) {
        if focusedOCR == id { focusedOCR = nil }
        hiddenOCRIDs.insert(id)
        assignments.removeValue(forKey: id)
        ocrEdits.removeValue(forKey: id)
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
            categoryMenu(selection: categoryBinding)
                .frame(maxWidth: .infinity, alignment: .leading)
            deleteButton {
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

    private func categoryMenu(selection: Binding<TechViewCategory?>) -> some View {
        Menu {
            ForEach(TechViewCategory.allCases) { category in
                Button {
                    selection.wrappedValue = category
                } label: {
                    Label(category.displayName, systemImage: category.symbolName)
                }
            }
        } label: {
            if let category = selection.wrappedValue {
                Label(category.displayName, systemImage: category.symbolName)
                    .labelStyle(.titleAndIcon)
                    .font(.subheadline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.22), in: Capsule())
                    .foregroundStyle(.white)
            } else {
                Label("Category", systemImage: "tag")
                    .labelStyle(.titleAndIcon)
                    .font(.subheadline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.secondary.opacity(0.22), in: Capsule())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func deleteButton(_ action: @escaping () -> Void) -> some View {
        Button(role: .destructive, action: action) {
            Label("Delete", systemImage: "trash")
                .labelStyle(.titleAndIcon)
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .buttonStyle(.bordered)
        .tint(.red)
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
