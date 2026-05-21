import SwiftUI
import UIKit

/// Bottom-sheet style annotation surface shown after a photo is
/// taken. Lists each OCR observation alongside a category picker so
/// the user can tag what it represents (origin, composition, care,
/// standards, restrictions, notes). Confidence shows as a small
/// monospaced percentage. "Save" + "Retake" buttons hand control
/// back to the parent capture view.
struct TechViewsAnnotationView: View {
    let image: UIImage
    let observations: [OCRObservation]
    let isRunningOCR: Bool
    @Binding var assignments: [UUID: TechViewCategory]
    let onRetake: () -> Void
    let onSave: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                preview
                annotationsList
                footer
            }
        }
    }

    private var preview: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: 260)
            .padding(.top, 8)
    }

    @ViewBuilder
    private var annotationsList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Detected text")
                    .font(.subheadline.weight(.medium))
                Spacer()
                if isRunningOCR {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Reading…").font(.caption)
                    }
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if observations.isEmpty && !isRunningOCR {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(observations) { obs in
                            observationRow(obs)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 16)
                }
            }
        }
        .background(.thinMaterial)
    }

    private var emptyState: some View {
        Text("No text detected on this shot.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
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
            Menu {
                Button("Ignore", role: .destructive) { binding.wrappedValue = nil }
                Divider()
                ForEach(TechViewCategory.allCases) { category in
                    Button {
                        binding.wrappedValue = category
                    } label: {
                        Label(category.displayName, systemImage: category.symbolName)
                    }
                }
            } label: {
                if let category = binding.wrappedValue {
                    Label(category.displayName, systemImage: category.symbolName)
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.accentColor.opacity(0.18), in: Capsule())
                } else {
                    Text("Ignore")
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.secondary.opacity(0.18), in: Capsule())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
