import SwiftUI
import UIKit

/// Bottom-sheet style annotation surface shown after a photo is
/// taken. Lists each OCR observation alongside a category picker so
/// the user can tag what it represents (origin, composition, care,
/// standards, restrictions, notes); below that, a Pictograms section
/// lets the user confirm or correct auto-detected non-textual icons.
/// "Save" + "Retake" buttons hand control back to the parent
/// capture view.
struct TechViewsAnnotationView: View {
    let image: UIImage
    let observations: [OCRObservation]
    let isRunningOCR: Bool
    let candidates: [TechViewsPictoDetection.Candidate]
    let isDetectingPictos: Bool
    @Binding var assignments: [UUID: TechViewCategory]
    @Binding var pictoAnnotations: [UUID: PictoAnnotation]
    let onRetake: () -> Void
    let onSave: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                preview
                annotationsScroll
                footer
            }
        }
    }

    private var preview: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: 220)
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

        if observations.isEmpty && !isRunningOCR {
            emptyState("No text detected on this shot.")
        } else {
            LazyVStack(spacing: 8) {
                ForEach(observations) { obs in
                    observationRow(obs)
                }
            }
        }
    }

    private func observationRow(_ obs: OCRObservation) -> some View {
        let binding = Binding<TechViewCategory?>(
            get: { assignments[obs.id] },
            set: { newValue in
                if let newValue {
                    assignments[obs.id] = newValue
                } else {
                    assignments.removeValue(forKey: obs.id)
                }
            }
        )
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(obs.text)
                    .font(.subheadline)
                Text("\(Int(obs.confidence * 100))%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            categoryMenu(selection: binding)
        }
        .padding(10)
        .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
        let annotationBinding = Binding<PictoAnnotation>(
            get: { pictoAnnotations[candidate.id] ?? PictoAnnotation(id: candidate.id, label: "", category: nil) },
            set: { pictoAnnotations[candidate.id] = $0 }
        )
        let labelBinding = Binding<String>(
            get: { annotationBinding.wrappedValue.label },
            set: { annotationBinding.wrappedValue.label = $0 }
        )
        let categoryBinding = Binding<TechViewCategory?>(
            get: { annotationBinding.wrappedValue.category },
            set: { annotationBinding.wrappedValue.category = $0 }
        )
        let suggested = annotationBinding.wrappedValue.matchedLearnedID != nil
        return HStack(alignment: .top, spacing: 10) {
            Image(uiImage: candidate.crop)
                .resizable()
                .interpolation(.medium)
                .aspectRatio(contentMode: .fit)
                .frame(width: 56, height: 56)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                TextField("Label (e.g. Wash 30°)", text: labelBinding)
                    .textInputAutocapitalization(.sentences)
                    .autocorrectionDisabled()
                    .font(.subheadline)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                if suggested, let distance = annotationBinding.wrappedValue.suggestionDistance {
                    Text(String(format: "Suggested · distance %.1f", distance))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            VStack(spacing: 6) {
                categoryMenu(selection: categoryBinding)
                Button {
                    pictoAnnotations.removeValue(forKey: candidate.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Shared

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
            Button("Ignore", role: .destructive) { selection.wrappedValue = nil }
            Divider()
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
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.accentColor.opacity(0.18), in: Capsule())
            } else {
                Text("Ignore")
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.secondary.opacity(0.18), in: Capsule())
                    .foregroundStyle(.secondary)
            }
        }
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
