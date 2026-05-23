import SwiftUI
import UIKit

/// Sheet shown when the user taps an OCR row in the annotation
/// view. Mirrors the visual rhythm of `PictoLabelPicker` via the
/// shared `TechViewEditorShell`: cropped preview at the top so the
/// user knows which region of the photo they're editing, a
/// multi-line text editor, the same category picker used
/// elsewhere, and a Delete button to drop a false-positive
/// observation outright. Cancel reverts every change made inside
/// the sheet; Done keeps the current edits.
struct OCRObservationEditor: View {
    let observation: OCRObservation
    let sourceImage: UIImage
    @Binding var ocrEdits: [UUID: String]
    @Binding var assignments: [UUID: TechViewCategory]
    @Binding var hiddenOCRIDs: Set<UUID>
    let onDismiss: () -> Void

    @State private var initialText: String
    @State private var initialCategory: TechViewCategory?
    @FocusState private var editorFocused: Bool

    init(
        observation: OCRObservation,
        sourceImage: UIImage,
        ocrEdits: Binding<[UUID: String]>,
        assignments: Binding<[UUID: TechViewCategory]>,
        hiddenOCRIDs: Binding<Set<UUID>>,
        onDismiss: @escaping () -> Void
    ) {
        self.observation = observation
        self.sourceImage = sourceImage
        self._ocrEdits = ocrEdits
        self._assignments = assignments
        self._hiddenOCRIDs = hiddenOCRIDs
        self.onDismiss = onDismiss
        let startingText = ocrEdits.wrappedValue[observation.id] ?? observation.text
        self._initialText = State(initialValue: startingText)
        self._initialCategory = State(initialValue: assignments.wrappedValue[observation.id])
    }

    private var textBinding: Binding<String> {
        Binding(
            get: { ocrEdits[observation.id] ?? observation.text },
            set: { ocrEdits[observation.id] = $0 }
        )
    }

    private var categoryBinding: Binding<TechViewCategory?> {
        Binding(
            get: { assignments[observation.id] },
            set: { newValue in
                if let newValue {
                    assignments[observation.id] = newValue
                } else {
                    assignments.removeValue(forKey: observation.id)
                }
            }
        )
    }

    var body: some View {
        TechViewEditorShell(
            title: "Edit text",
            onCancel: revert,
            dismissKeyboard: { editorFocused = false },
            primaryAction: {
                Button("Done") { onDismiss() }
            }
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    cropPreview
                    editor
                    confidenceLine
                    categorySection
                    Spacer(minLength: 8)
                    TechViewDeleteButton(action: delete)
                        .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
        }
        .presentationDetents([.large])
        .onAppear { editorFocused = true }
    }

    @ViewBuilder
    private var cropPreview: some View {
        if let cropped = techViewsCrop(of: sourceImage, box: observation.boundingBox) {
            Image(uiImage: cropped)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .frame(maxHeight: 140)
                .background(Color.gray.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Text")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            TextEditor(text: textBinding)
                .focused($editorFocused)
                .font(.body)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .scrollContentBackground(.hidden)
                .frame(minHeight: 120, maxHeight: 240)
                .padding(8)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.secondary.opacity(0.25))
                )
        }
    }

    private var confidenceLine: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.seal")
                .foregroundStyle(.secondary)
            Text("OCR confidence: \(Int(observation.confidence * 100))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var categorySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Category")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            TechViewCategoryControl(selection: categoryBinding)
        }
    }

    // MARK: - Actions

    private func revert() {
        if initialText == observation.text {
            ocrEdits.removeValue(forKey: observation.id)
        } else {
            ocrEdits[observation.id] = initialText
        }
        if let initialCategory {
            assignments[observation.id] = initialCategory
        } else {
            assignments.removeValue(forKey: observation.id)
        }
        onDismiss()
    }

    private func delete() {
        hiddenOCRIDs.insert(observation.id)
        ocrEdits.removeValue(forKey: observation.id)
        assignments.removeValue(forKey: observation.id)
        onDismiss()
    }
}
